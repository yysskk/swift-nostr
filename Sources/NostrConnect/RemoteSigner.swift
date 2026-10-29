import Foundation
public import NostrCore

/// A session with a NIP-46 remote signer (a "bunker"), driven over a relay transport.
///
/// The user's private key never leaves the signer. This actor holds a separate *client* identity,
/// encrypts a request to the signer, signs a kind-24133 event with the client key, sends it to the
/// signer's relays, and awaits the matching response — correlated by the `id` field inside the
/// decrypted JSON body (not by any event tag). Build one from a signer-issued ``BunkerURI`` (the
/// `bunker://` flow) or from a client-generated ``NostrConnectURI`` invitation (the `nostrconnect://`
/// flow, see `RemoteSigner+NostrConnect`), then call the typed commands (see `RemoteSigner+Commands`),
/// or ``send(_:params:)`` for a method without one.
///
/// ### Connecting
/// Call ``connect()`` in either flow. For a `bunker://` session it sends the first `connect`
/// request, presenting the bunker secret when the token carries one. For a `nostrconnect://`
/// session the signer initiates instead, so it waits for the signer's first response, whose echoed
/// secret both authenticates it and reveals its public key.
///
/// ### Authentication challenges
/// A signer may answer a request with an `auth_url` challenge instead of a result, asking the user
/// to authorize the operation in a browser. The originating request stays pending — its timeout is
/// extended to ``Config/authChallengeTimeout`` — while the challenge URL is delivered on
/// ``authChallenges()``; the real response arrives later with the same id.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public actor RemoteSigner {
    /// Session behavior.
    public struct Config: Sendable, Hashable {
        /// How long to wait for a response before failing a request. Default: 30 seconds.
        public var requestTimeout: Duration

        /// How long a request may stay pending after an `auth_url` challenge, giving the user time
        /// to authorize. Default: 300 seconds.
        public var authChallengeTimeout: Duration

        /// Creates a session configuration.
        /// - Parameters:
        ///   - requestTimeout: How long to wait for a response before failing a request.
        ///   - authChallengeTimeout: How long a request may stay pending after an `auth_url`
        ///     challenge.
        public init(requestTimeout: Duration = .seconds(30), authChallengeTimeout: Duration = .seconds(300)) {
            self.requestTimeout = requestTimeout
            self.authChallengeTimeout = authChallengeTimeout
        }
    }

    private static let responseSubscriptionID: SubscriptionID = "nip46-responses"

    /// The shared relay session, correlating each request by the `id` in its JSON body and holding
    /// the request's method so an `auth_url` challenge can be labeled with it.
    private typealias Session = RequestResponseSession<
        String, RemoteSignerMethod, RemoteSignerResponse, RemoteSignerError
    >

    private let session: Session
    private let config: Config
    private let clientKeyPair: KeyPair
    private let signer: EventSigner
    private let secret: String?

    /// The local client identity's public key. The user's key never leaves the signer.
    public nonisolated let clientPublicKey: PublicKey

    /// The remote signer's public key. Known up front for a `bunker://` session; `nil` for a
    /// client-initiated `nostrconnect://` session until ``connect()`` discovers it from the
    /// signer's first valid response.
    private var signerPublicKey: PublicKey?

    /// The connection secret a `nostrconnect://` invitation expects the signer to echo back, used to
    /// authenticate the signer before its public key is pinned. `nil` for a `bunker://` session.
    private let expectedInvitationSecret: String?

    /// The permissions this client asks the signer to grant in its `connect` call.
    ///
    /// Only the `bunker://` flow sends these: it is the client that initiates the handshake there.
    /// A `nostrconnect://` session carries its permissions in the invitation URI the signer reads,
    /// and the client never sends `connect` at all — so the two are kept apart rather than folded
    /// into one list that would be sent in the wrong place.
    ///
    /// Granting and enforcing them is the remote signer's job; this is the request.
    private let requestedPermissions: [RemoteSignerPermission]

    private var didConnect = false

    /// The ``connect()`` attempt in flight, which concurrent calls join rather than repeat.
    private let connectOperation = SharedOperation<Void, RemoteSignerError>(cancelledError: .cancelled)

    /// Open auth-challenge streams, keyed so each can deregister on termination.
    private var authChallengeStreams: [UUID: AsyncStream<RemoteSignerAuthChallenge>.Continuation] = [:]

    /// When each challenged request stops being extendable, keyed by request id. Set by the first
    /// `auth_url` for a request so that repeats cannot postpone it indefinitely.
    private var authChallengeDeadlines: [String: ContinuousClock.Instant] = [:]

    /// The number of challenged requests still holding a deadline (for tests).
    var authChallengeDeadlineCount: Int { authChallengeDeadlines.count }
    /// The user's public key (`get_public_key`), cached after the first fetch.
    private var cachedUserPublicKey: PublicKey?
    /// The first ``publicKey`` fetch in flight, which concurrent reads join rather than repeat.
    private let userPublicKeyOperation = SharedOperation<PublicKey, RemoteSignerError>(cancelledError: .cancelled)

    /// The waiter of the `nostrconnect://` discovery ``connect()`` runs, resolved once a valid
    /// connect response (echoing the invitation secret) arrives, or the wait times out. `nil` when
    /// not awaiting.
    private var connectionWaiter: ConnectionWaiter?
    /// A discovered signer public key from a valid connect response that arrived before
    /// the discovery registered its waiter (the response can be delivered as soon as the
    /// subscription exists, which is before the waiter is set). Consumed when the waiter registers so
    /// the acknowledgement is never lost to that window.
    private var bufferedDiscovery: PublicKey?
    /// Fails the connection waiter if no valid connect response arrives in time.
    private var connectionTimeoutTask: Task<Void, Never>?

    /// Creates a session from a signer-issued `bunker://` token.
    /// - Parameters:
    ///   - bunker: The parsed token.
    ///   - clientKeyPair: The local client identity; a fresh random keypair by default. Pass a
    ///     persisted one to resume an authorized session.
    ///   - permissions: The operations to ask the signer to grant during ``connect()``, so it can
    ///     authorize them once rather than challenging the user for each. Empty by default, which
    ///     leaves them out of the request entirely. Granting and enforcing them is the signer's
    ///     side of the exchange.
    ///   - transport: The relay transport. Defaults to a `RelayConnectionTransport` over the
    ///     token's relays; inject a custom one (e.g. for tests).
    ///   - config: Session behavior.
    public init(
        bunker: BunkerURI,
        clientKeyPair: KeyPair? = nil,
        requesting permissions: [RemoteSignerPermission] = [],
        transport: (any RelayTransport)? = nil,
        config: Config = Config()
    ) {
        let keyPair = clientKeyPair ?? KeyPair()
        self.clientKeyPair = keyPair
        self.signer = EventSigner(keyPair: keyPair)
        self.clientPublicKey = keyPair.publicKey
        self.signerPublicKey = bunker.remoteSignerPublicKey
        self.secret = bunker.secret
        self.expectedInvitationSecret = nil
        self.requestedPermissions = permissions
        self.config = config
        self.session = Session(
            transport: transport
                ?? RelayConnectionTransport(relayURLs: bunker.relays),
            mapError: RemoteSignerError.init)
    }

    /// Creates a client-initiated session, without validating anything at this layer.
    ///
    /// The public entry point is ``init(invitation:clientKeyPair:transport:config:)`` in
    /// `RemoteSigner+NostrConnect`, which validates the invitation before calling this.
    init(
        clientKeyPair: KeyPair,
        expectedInvitationSecret: String,
        transport: any RelayTransport,
        config: Config
    ) {
        self.clientKeyPair = clientKeyPair
        self.signer = EventSigner(keyPair: clientKeyPair)
        self.clientPublicKey = clientKeyPair.publicKey
        self.signerPublicKey = nil
        self.secret = nil
        self.expectedInvitationSecret = expectedInvitationSecret
        // The invitation URI already carries this flow's permissions, and the client never sends
        // `connect` here, so there is nothing for this list to be sent in.
        self.requestedPermissions = []
        self.config = config
        self.session = Session(
            transport: transport,
            mapError: RemoteSignerError.init)
    }

    /// The remote signer's public key, or `nil` for a client-initiated `nostrconnect://` session
    /// before ``connect()`` has discovered it. Known immediately for a `bunker://` session.
    /// Not necessarily the user's key (see ``publicKey``).
    public var remoteSignerPublicKey: PublicKey? {
        signerPublicKey
    }

    // MARK: - Lifecycle

    /// Establishes the session with the remote signer, in either flow.
    ///
    /// - For a `bunker://` session, connects to the relays, subscribes for responses, and performs
    ///   the `connect` handshake, presenting the bunker secret when the token carries one and the
    ///   requested permissions when there are any.
    /// - For a `nostrconnect://` session, connects and waits for the signer to accept the
    ///   invitation: the first response whose result echoes the invitation secret (per NIP-46, the
    ///   client MUST validate the returned secret). Its sender becomes the remote signer, and later
    ///   traffic is pinned to it. A response whose result does *not* equal the secret is treated as
    ///   a spoofing attempt and ignored: the wait continues until the correct secret arrives or the
    ///   wait times out.
    ///
    /// Once this returns, ``remoteSignerPublicKey`` is non-nil and the typed commands work. Calling
    /// it again after it has succeeded is a no-op. Concurrent calls share one attempt — one
    /// `connect` request, one wait for the invitation reply — and all receive its result, success
    /// or the same error. A caller whose task is cancelled stops waiting with
    /// ``RemoteSignerError/cancelled`` without ending the attempt for the others; the attempt is
    /// abandoned only when every caller waiting on it has been cancelled.
    ///
    /// The typed commands call this themselves on a `nostrconnect://` session whose signer is not
    /// yet known; call it explicitly to surface connection errors up front.
    /// - Throws: ``RemoteSignerError/connectionRejected(message:)`` if a `bunker://` signer declines
    ///   or returns a secret other than the one sent, ``RemoteSignerError/timedOut`` if the signer
    ///   does not answer within ``Config/requestTimeout``, ``RemoteSignerError/notConnected`` if
    ///   the session ends first — on ``disconnect()``, or when the relays' streams end —
    ///   ``RemoteSignerError/cancelled`` if the calling task is cancelled,
    ///   ``RemoteSignerError/transportFailed(_:)`` if the relay cannot be connected to or the
    ///   request cannot be sent, or what ``send(_:params:)`` throws.
    public func connect() async throws(RemoteSignerError) {
        try await connectOperation.run { [weak self] in
            guard let self else { return .failure(.notConnected) }
            return await self.connectAttempt()
        }
    }

    /// One shared ``connect()`` attempt: starts the session, then runs the flow's handshake.
    private func connectAttempt() async -> Result<Void, RemoteSignerError> {
        do throws(RemoteSignerError) {
            try await ensureStarted()
            if expectedInvitationSecret != nil {
                try await discoverSigner()
            } else {
                try await performHandshake()
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Sends the `bunker://` flow's `connect` request and checks the signer's answer.
    private func performHandshake() async throws(RemoteSignerError) {
        guard !didConnect else { return }

        let signerPublicKey = try requireSignerPublicKey()
        // NIP-46's connect takes `[signerPublicKey, secret, perms]`. The secret is included only when
        // the token carries one; an older signer may echo it back instead of "ack", so accept
        // either. The permissions go in the third slot, which is positional — so an empty secret
        // still has to be sent when there are permissions to name after it. Without them every
        // operation had to be authorized interactively, one `auth_url` round-trip at a time.
        var params = [signerPublicKey.hex]
        if secret != nil || !requestedPermissions.isEmpty {
            params.append(secret ?? "")
        }
        if !requestedPermissions.isEmpty {
            params.append(requestedPermissions.map(\.rawValue).joined(separator: ","))
        }

        let response = try await sendRequest(method: .connect, params: params)
        let result = response.result
        guard result == "ack" || (secret != nil && result.map({ Self.constantTimeEquals($0, secret!) }) == true)
        else {
            throw .connectionRejected(message: result ?? "")
        }
        didConnect = true
    }

    /// Compares two secrets without letting the comparison's duration depend on how much of them
    /// matched.
    ///
    /// These are short-lived connection secrets carried over a relay, so a timing attack is not
    /// practical — but a secret comparison is the wrong place to keep a shortcut, and the correct
    /// primitive costs nothing here.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    /// Sends `logout` (best effort) and disconnects.
    public func logout() async {
        if await session.isStarted {
            _ = try? await sendRequest(method: .logout, params: [])
        }
        await disconnect()
    }

    /// Disconnects without notifying the signer, failing any in-flight requests with
    /// ``RemoteSignerError/notConnected`` and ending the auth-challenge streams.
    public func disconnect() async {
        didConnect = false
        bufferedDiscovery = nil

        sessionEnded()

        // Every in-flight request is failed below, so no deadline is still owed an answer. Left
        // behind, these accumulate one entry per request that ended any way other than the signer
        // eventually replying — an abandoned `auth_url` prompt, a timeout, a teardown.
        authChallengeDeadlines.removeAll()

        await session.disconnect()
    }

    /// Connects, subscribes for responses, and starts reading them — once per session.
    private func ensureStarted() async throws(RemoteSignerError) {
        try await session.ensureStarted(
            subscriptionID: Self.responseSubscriptionID,
            filters: [responseFilter]
        ) { [weak self] event in
            await self?.handle(event: event)
        } onEnded: { [weak self] in
            // The relays' streams ended. A restart waits for this handler, so the waiter and streams
            // it ends are never a newer session's.
            await self?.sessionEnded()
        }
    }

    /// Fails a pending ``connect()`` discovery and ends the auth-challenge streams: nothing can
    /// answer either once the session has ended.
    private func sessionEnded() {
        failConnection(with: .notConnected)
        finishAuthChallengeStreams()
    }

    // MARK: - Auth challenges

    /// A stream of `auth_url` challenges. Display each ``RemoteSignerAuthChallenge/url`` to the user
    /// (typically in a browser); the originating request stays pending until the signer answers it
    /// or the ``Config/authChallengeTimeout`` elapses.
    ///
    /// Multiple concurrent streams are supported; each finishes when its task is cancelled or the
    /// session ends — on ``disconnect()``, or when the relays' streams end because automatic
    /// reconnection gave up.
    ///
    /// This registers the stream and returns it without connecting. Call ``connect()`` (or send any
    /// command) to start receiving; a stream obtained after the session ended receives the
    /// challenges of the next request, which reconnects.
    public func authChallenges() -> AsyncStream<RemoteSignerAuthChallenge> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<RemoteSignerAuthChallenge>.makeStream()
        authChallengeStreams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeAuthChallengeStream(id) }
        }
        return stream
    }

    private func removeAuthChallengeStream(_ id: UUID) {
        authChallengeStreams[id] = nil
    }

    /// Ends every open auth-challenge stream, so a consumer's `for await` loop exits.
    private func finishAuthChallengeStreams() {
        for stream in authChallengeStreams.values {
            stream.finish()
        }
        authChallengeStreams.removeAll()
    }

    // MARK: - Requests

    /// Sends a request and awaits its response, correlated by the request `id`.
    ///
    /// Registers a waiter under the request `id`, starts a timeout, sends the encrypted event, and
    /// returns the matching response. An `auth_url` challenge does not resolve the request: its
    /// timeout is extended to ``Config/authChallengeTimeout`` and the real response arrives later
    /// with the same id.
    /// - Throws: What ``send(_:params:)`` throws, except ``RemoteSignerError/responseDecodingFailed``
    ///   for a response without a result.
    func sendRequest(
        method: RemoteSignerMethod, params: [String]
    ) async throws(RemoteSignerError) -> RemoteSignerResponse {
        try await ensureStarted()

        let request = RemoteSignerRequest(method: method, params: params)
        // Cleared where the request's life actually ends, whatever ends it. Removing it only when a
        // later non-challenge response arrives missed the common case — a signer that sends one
        // `auth_url` and never follows up, leaving the session's own timer to end the request — so
        // a long-lived signer accumulated an entry per abandoned prompt.
        defer { authChallengeDeadlines.removeValue(forKey: request.id) }

        let event = try buildRequestEvent(request)
        let response = try await session.perform(
            event, key: request.id, state: method, timeout: config.requestTimeout)

        if let message = response.error, !response.isAuthChallenge {
            throw .signerError(message: message)
        }
        return response
    }

    private func buildRequestEvent(_ request: RemoteSignerRequest) throws(RemoteSignerError) -> Event {
        // The signer's public key must be known before any request can be addressed to it — always true
        // for a bunker session, and true for a nostrconnect session once connect() resolves.
        let signerPublicKey = try requireSignerPublicKey()
        do {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            let encrypted = try NIP44Payload.encrypt(json, for: signerPublicKey, using: clientKeyPair)
            let unsigned = UnsignedEvent(
                publicKey: clientKeyPair.publicKey,
                kind: .nostrConnect,
                tags: [.publicKey(signerPublicKey)],
                content: encrypted.base64)
            return try signer.sign(unsigned)
        } catch {
            throw .requestEncodingFailed
        }
    }

    // MARK: - Incoming events

    private func handle(event: Event) async {
        // A client-initiated (nostrconnect://) session does not yet know the signer's public key: the
        // first valid response echoing the invitation secret both authenticates the signer and
        // reveals it. Route such events to the connection waiter instead of the request path.
        guard let signerPublicKey else {
            handleConnectionCandidate(event)
            return
        }

        // The relay filter already restricts authors, but enforce it here too as defense in depth:
        // ignore anything that is not from the signer.
        guard event.publicKey == signerPublicKey else { return }

        let payload = NIP44Payload(base64: event.content)
        guard
            let content = try? payload.decrypt(from: event.publicKey, using: clientKeyPair),
            let response = try? JSONDecoder().decode(RemoteSignerResponse.self, from: Data(content.utf8))
        else {
            return
        }

        // An `auth_url` challenge does not answer the request: it stays pending until the signer
        // sends the real response with the same id, on a timeout long enough for the user to
        // authorize. Anything else resolves it.
        let challengeURL = response.isAuthChallenge ? response.error.flatMap(URL.init(string:)) : nil

        // Every challenge replaces the request's timeout, so a signer that keeps sending them could
        // hold a caller suspended with no end. The first one fixes a deadline for the request, and
        // later ones may only postpone it up to that — the window stays the one the caller
        // configured however many challenges arrive.
        let now = ContinuousClock.now
        let deadline = challengeURL.map { _ in
            authChallengeDeadlines[response.id] ?? now + config.authChallengeTimeout
        }
        let remainingAfterChallenge = deadline.map { now.duration(to: $0) } ?? .zero

        let method = await session.withPendingRequest(response.id) { _ in
            guard challengeURL != nil else { return .resolved(response) }
            guard remainingAfterChallenge > .zero else {
                return .failed(.timedOut)
            }
            return .pendingFor(remainingAfterChallenge)
        }

        // Recorded only once a request is known to be waiting on it. Writing before that check let
        // a stray or duplicate `auth_url` — one whose id matches nothing in flight, or whose
        // request has already finished and run its cleanup — leave behind an entry with no
        // `sendRequest` left to remove it.
        if method != nil, let deadline, remainingAfterChallenge > .zero {
            authChallengeDeadlines[response.id] = deadline
        } else {
            authChallengeDeadlines.removeValue(forKey: response.id)
        }

        // No pending request (an unknown or already-resolved id), or the response resolved it.
        guard let method, let challengeURL else { return }

        let challenge = RemoteSignerAuthChallenge(url: challengeURL, method: method, requestID: response.id)
        for stream in authChallengeStreams.values {
            stream.yield(challenge)
        }
    }

    // MARK: - Client-initiated connection

    /// Waits for the signer to accept a `nostrconnect://` invitation and pins the session to its
    /// discovered public key. Backs ``connect()`` for that flow; see it for the full contract.
    private func discoverSigner() async throws(RemoteSignerError) {
        // Already discovered (e.g. a repeat call): nothing to wait for.
        guard signerPublicKey == nil else { return }

        let signerPublicKey: PublicKey
        if let buffered = bufferedDiscovery {
            // A valid connect response already arrived while we were starting up.
            bufferedDiscovery = nil
            signerPublicKey = buffered
        } else {
            signerPublicKey = try await waitForSigner()
        }

        // Pin subsequent traffic to the now-known signer (defense in depth) and mark connected.
        self.signerPublicKey = signerPublicKey
        didConnect = true
        try? await session.subscribe(id: Self.responseSubscriptionID, filters: [responseFilter])
    }

    /// Registers the connection waiter and suspends until the signer's connect response resolves it,
    /// the wait times out, the session ends, or the calling task is cancelled.
    private func waitForSigner() async throws(RemoteSignerError) -> PublicKey {
        // Only one attempt waits at a time, except that an attempt every caller abandoned may still
        // be winding down when the next starts. Retire its waiter and timeout first, so its timer
        // cannot fail this wait early.
        failConnection(with: .cancelled)

        let (stream, continuation) = AsyncStream<Result<PublicKey, RemoteSignerError>>.makeStream()
        let waiter = ConnectionWaiter(continuation: continuation)
        connectionWaiter = waiter
        let timeout = config.requestTimeout
        connectionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.failConnection(with: .timedOut)
        }

        // Every outcome yields a result, so the stream ends without one only on cancellation.
        for await result in stream {
            return try result.get()
        }
        // Withdraw the wait so a later attempt can start another — unless it has already been
        // settled, and the slot may hold that later attempt's waiter.
        if connectionWaiter?.id == waiter.id {
            failConnection(with: .cancelled)
        }
        throw .cancelled
    }

    /// Inspects an event received before the signer is known: if it decrypts to a response whose
    /// result echoes the expected invitation secret, it is the authentic connect acknowledgement, so
    /// resolve the waiter with the sender's public key. Anything else (including a mismatched secret from
    /// a spoofer) is ignored so the client keeps waiting for the correct response.
    private func handleConnectionCandidate(_ event: Event) {
        guard let expectedInvitationSecret else { return }

        let payload = NIP44Payload(base64: event.content)
        guard
            let content = try? payload.decrypt(from: event.publicKey, using: clientKeyPair),
            let response = try? JSONDecoder().decode(RemoteSignerResponse.self, from: Data(content.utf8)),
            response.result.map({ Self.constantTimeEquals($0, expectedInvitationSecret) }) == true
        else {
            return
        }

        if connectionWaiter != nil {
            resolveConnection(with: event.publicKey)
        } else {
            // The waiter isn't registered yet (the response arrived between the subscription being
            // created and the discovery suspending); hold the public key for it to pick up.
            bufferedDiscovery = event.publicKey
        }
    }

    /// Resolves the pending discovery waiter with the discovered signer public key.
    private func resolveConnection(with signerPublicKey: PublicKey) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let waiter = connectionWaiter
        connectionWaiter = nil
        waiter?.continuation.yield(.success(signerPublicKey))
        waiter?.continuation.finish()
    }

    /// Fails the pending discovery waiter (on timeout, when the session ends, or when its attempt is
    /// cancelled).
    private func failConnection(with error: RemoteSignerError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let waiter = connectionWaiter
        connectionWaiter = nil
        waiter?.continuation.yield(.failure(error))
        waiter?.continuation.finish()
    }

    /// The signer's public key, or throws ``RemoteSignerError/notConnected`` if it is not yet known (a
    /// nostrconnect session before ``connect()`` resolves).
    private func requireSignerPublicKey() throws(RemoteSignerError) -> PublicKey {
        guard let signerPublicKey else { throw .notConnected }
        return signerPublicKey
    }

    // MARK: - Raw requests

    /// Sends a request for `method` and returns the `result` string of the signer's response.
    ///
    /// The typed commands are built on this; call it directly for a method that has no typed
    /// wrapper, such as one specific to a particular signer. An `auth_url` challenge keeps the
    /// request pending exactly as it does for a typed command (see ``authChallenges()``).
    ///
    /// On a `nostrconnect://` session whose signer is not yet known, this first runs ``connect()``
    /// — or joins the call already in flight — and sends the request once the signer has accepted
    /// the invitation. Each phase has its own ``Config/requestTimeout``.
    ///
    /// ```swift
    /// let info = try await signer.send(RemoteSignerMethod(rawValue: "get_session_info"))
    /// ```
    /// - Parameters:
    ///   - method: The method to invoke.
    ///   - params: The method's positional string arguments.
    /// - Returns: The response's `result`, uninterpreted.
    /// - Throws: ``RemoteSignerError/signerError(message:)`` if the signer answers with an error,
    ///   ``RemoteSignerError/responseDecodingFailed`` if the response carries no result,
    ///   ``RemoteSignerError/timedOut`` if it does not answer in time,
    ///   ``RemoteSignerError/notConnected`` if the session disconnects while the request is
    ///   pending, ``RemoteSignerError/requestEncodingFailed`` if the request cannot be encrypted or
    ///   signed, ``RemoteSignerError/cancelled`` if the calling task is cancelled — before the send,
    ///   nothing is sent — ``RemoteSignerError/transportFailed(_:)`` if the relay cannot be
    ///   connected to or the request cannot be sent, or what ``connect()`` throws while it waits for
    ///   a `nostrconnect://` signer.
    public func send(_ method: RemoteSignerMethod, params: [String] = []) async throws(RemoteSignerError) -> String {
        if signerPublicKey == nil {
            try await connect()
        }
        let response = try await sendRequest(method: method, params: params)
        guard let result = response.result else {
            throw .responseDecodingFailed
        }
        return result
    }

    // MARK: - Commands support

    /// The user's public key: the cached value, or the result of one `get_public_key` request that
    /// concurrent first reads share. Backs ``publicKey``.
    func resolveUserPublicKey() async throws(RemoteSignerError) -> PublicKey {
        if let cachedUserPublicKey { return cachedUserPublicKey }
        return try await userPublicKeyOperation.run { [weak self] in
            guard let self else { return .failure(.notConnected) }
            return await self.fetchUserPublicKey()
        }
    }

    /// One shared `get_public_key` fetch, caching the key it validates.
    private func fetchUserPublicKey() async -> Result<PublicKey, RemoteSignerError> {
        // A read that missed the cache just before an earlier fetch finished starts a new attempt;
        // the key is cached by then, so nothing is sent again.
        if let cachedUserPublicKey { return .success(cachedUserPublicKey) }
        do throws(RemoteSignerError) {
            let reply = try await send(.getPublicKey)
            guard let publicKey = PublicKey(reply) else {
                return .failure(.responseValidationFailed)
            }
            cachedUserPublicKey = publicKey
            return .success(publicKey)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Filters

    /// The subscription filter for incoming responses. It pins `authors` to the signer once known
    /// (a bunker session, or a nostrconnect session after discovery); before a nostrconnect signer
    /// is known it omits `authors` so the client can receive the connect response from any public key.
    private var responseFilter: Filter {
        Filter(
            authors: signerPublicKey.map { [$0] }, kinds: [.nostrConnect],
            publicKeyReferences: [clientKeyPair.publicKey])
    }

    // MARK: - Testing

    /// Whether the `connect` handshake has completed. Exposed for tests.
    var isConnectedForTesting: Bool {
        didConnect
    }

    /// Whether a `nostrconnect://` discovery is currently suspended. Exposed for tests.
    var isAwaitingConnectionForTesting: Bool {
        connectionWaiter != nil
    }

    /// How many ``connect()`` callers are waiting on the attempt in flight. Exposed for tests.
    var connectWaiterCountForTesting: Int {
        get async { await connectOperation.waiterCount }
    }

    /// How many ``publicKey`` readers are waiting on the fetch in flight. Exposed for tests.
    var publicKeyWaiterCountForTesting: Int {
        get async { await userPublicKeyOperation.waiterCount }
    }
}

/// The waiter of a `nostrconnect://` discovery, identified so a cancelled wait withdraws only
/// itself.
private struct ConnectionWaiter {
    let id = UUID()
    let continuation: AsyncStream<Result<PublicKey, RemoteSignerError>>.Continuation
}

extension RemoteSignerError {
    /// The error a failure of the shared relay session surfaces as.
    init(_ failure: RequestResponseSessionError) {
        switch failure {
        case .timedOut:
            self = .timedOut
        case .notConnected:
            self = .notConnected
        case .cancelled:
            self = .cancelled
        case .transportFailed(let error):
            self = .transportFailed(error)
        case .duplicateRequestKey:
            // Requests are keyed by 16 random bytes, so a collision means the request was built
            // wrong.
            self = .requestEncodingFailed
        }
    }
}
