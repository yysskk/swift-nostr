import Foundation
public import NostrCore

/// A session with a NIP-46 remote signer (a "bunker"), driven over a relay transport.
///
/// The user's private key never leaves the signer. This actor holds a separate *client* identity,
/// encrypts a request to the signer, signs a kind-24133 event with the client key, sends it to the
/// signer's relays, and awaits the matching response — correlated by the `id` field inside the
/// decrypted JSON body (not by any event tag). Build one from a signer-issued ``BunkerURI`` (the
/// `bunker://` flow) or from a client-generated ``NostrConnectURI`` invitation (the `nostrconnect://`
/// flow, see `RemoteSigner+NostrConnect`), then call the typed commands (see `RemoteSigner+Commands`).
///
/// ### The connect handshake
/// For a `bunker://` session the client sends the first `connect` request, presenting the bunker
/// secret when the token carries one; call ``connect()`` to run it. For a `nostrconnect://` session
/// the signer initiates instead: ``awaitConnection()`` waits for the signer's first response, whose
/// echoed secret both authenticates it and reveals its pubkey.
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
    public struct Config: Sendable {
        /// How long to wait for a response before failing a request. Default: 30 seconds.
        public var requestTimeout: TimeInterval

        /// How long a request may stay pending after an `auth_url` challenge, giving the user time
        /// to authorize. Default: 300 seconds.
        public var authChallengeTimeout: TimeInterval

        public init(requestTimeout: TimeInterval = 30, authChallengeTimeout: TimeInterval = 300) {
            self.requestTimeout = requestTimeout
            self.authChallengeTimeout = authChallengeTimeout
        }
    }

    private static let responseSubscriptionID = "nip46-responses"

    /// The shared relay session, correlating each request by the `id` in its JSON body and holding
    /// the request's method so an `auth_url` challenge can be labeled with it.
    private typealias Session = RequestResponseSession<String, RemoteSignerMethod, RemoteSignerResponse>

    private let session: Session
    private let config: Config
    private let clientKeyPair: KeyPair
    private let signer: EventSigner
    private let secret: String?

    /// The local client identity's public key (hex). The user's key never leaves the signer.
    public nonisolated let clientPublicKey: String

    /// The remote signer's public key (hex). Known up front for a `bunker://` session; `nil` for a
    /// client-initiated `nostrconnect://` session until ``awaitConnection()`` discovers it from the
    /// signer's first valid response.
    private var signerPubkey: String?

    /// The connection secret a `nostrconnect://` invitation expects the signer to echo back, used to
    /// authenticate the signer before its pubkey is pinned. `nil` for a `bunker://` session.
    private let expectedInvitationSecret: String?

    private var didConnect = false

    /// Open auth-challenge streams, keyed so each can deregister on termination.
    private var authChallengeStreams: [UUID: AsyncStream<RemoteSignerAuthChallenge>.Continuation] = [:]
    /// The user's public key (`get_public_key`), cached after the first fetch.
    private var cachedUserPublicKey: String?

    /// The waiter suspended in ``awaitConnection()``, resolved once a valid connect response
    /// (echoing the invitation secret) arrives, or the wait times out. `nil` when not awaiting.
    private var connectionWaiter: CheckedContinuation<String, any Error>?
    /// A discovered signer pubkey from a valid connect response that arrived before
    /// ``discoverSigner()`` registered its waiter (the response can be delivered as soon as the
    /// subscription exists, which is before the waiter is set). Consumed when the waiter registers so
    /// the acknowledgement is never lost to that window.
    private var bufferedDiscovery: String?
    /// Fails the connection waiter if no valid connect response arrives in time.
    private var connectionTimeoutTask: Task<Void, Never>?

    /// Creates a session from a signer-issued `bunker://` token.
    /// - Parameters:
    ///   - bunker: The parsed token.
    ///   - clientKeyPair: The local client identity; a fresh random keypair by default. Pass a
    ///     persisted one to resume an authorized session.
    ///   - transport: The relay transport. Defaults to a `RelayConnectionTransport` over the
    ///     token's relays; inject a custom one (e.g. for tests).
    ///   - config: Session behavior.
    /// - Throws: An error if `clientKeyPair` is `nil` and a fresh keypair cannot be generated.
    public init(
        bunker: BunkerURI,
        clientKeyPair: KeyPair? = nil,
        transport: (any RelayTransport)? = nil,
        config: Config = Config()
    ) throws {
        let keyPair = try clientKeyPair ?? KeyPair()
        self.clientKeyPair = keyPair
        self.signer = EventSigner(keyPair: keyPair)
        self.clientPublicKey = keyPair.publicKeyHex
        self.signerPubkey = bunker.remoteSignerPubkey
        self.secret = bunker.secret
        self.expectedInvitationSecret = nil
        self.config = config
        self.session = Session(
            transport: transport ?? RelayConnectionTransport(relayURLs: bunker.relays),
            timedOut: RemoteSignerError.timedOut,
            notConnected: RemoteSignerError.notConnected)
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
        self.clientPublicKey = clientKeyPair.publicKeyHex
        self.signerPubkey = nil
        self.secret = nil
        self.expectedInvitationSecret = expectedInvitationSecret
        self.config = config
        self.session = Session(
            transport: transport,
            timedOut: RemoteSignerError.timedOut,
            notConnected: RemoteSignerError.notConnected)
    }

    /// The remote signer's public key (hex), or `nil` for a client-initiated `nostrconnect://`
    /// session before ``awaitConnection()`` has discovered it. Known immediately for a `bunker://`
    /// session. Not necessarily the user's key (see ``userPublicKey()``).
    public var remoteSignerPubkey: String? {
        signerPubkey
    }

    // MARK: - Lifecycle

    /// Connects, subscribes to responses, and performs the `connect` handshake, presenting the
    /// bunker secret when the token carries one. Commands call this automatically; call it
    /// explicitly to surface connection errors up front. Calling it again after a successful
    /// handshake is a no-op.
    /// - Throws: ``RemoteSignerError/connectionRejected(message:)`` if the signer declines,
    ///   ``RemoteSignerError/timedOut`` if it does not answer in time, or a transport error.
    public func connect() async throws {
        try await ensureStarted()
        guard !didConnect else { return }

        let signerPubkey = try requireSignerPubkey()
        // Include the secret only when the token carries one; an older signer may echo it back
        // instead of "ack", so accept either.
        let params = secret.map { [signerPubkey, $0] } ?? [signerPubkey]
        let response = try await sendRequest(method: .connect, params: params)
        let result = response.result
        guard result == "ack" || (secret != nil && result == secret) else {
            throw RemoteSignerError.connectionRejected(message: result ?? "")
        }
        didConnect = true
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

        // Fail a pending awaitConnection() waiter, if any.
        failConnection(with: .notConnected)

        for stream in authChallengeStreams.values {
            stream.finish()
        }
        authChallengeStreams.removeAll()

        await session.disconnect()
    }

    /// Connects, subscribes for responses, and starts reading them — once per session.
    private func ensureStarted() async throws {
        try await session.ensureStarted(
            subscriptionID: Self.responseSubscriptionID,
            filters: [responseFilter]
        ) { [weak self] event in
            await self?.handle(event: event)
        }
    }

    // MARK: - Auth challenges

    /// A stream of `auth_url` challenges. Display each ``RemoteSignerAuthChallenge/url`` to the user
    /// (typically in a browser); the originating request stays pending until the signer answers it
    /// or the ``Config/authChallengeTimeout`` elapses.
    ///
    /// Multiple concurrent streams are supported; each ends when its task is cancelled or the
    /// session is disconnected.
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

    // MARK: - Requests

    /// Sends a request and awaits its response, correlated by the request `id`.
    ///
    /// Registers a waiter under the request `id`, starts a timeout, sends the encrypted event, and
    /// returns the matching response. An `auth_url` challenge does not resolve the request: its
    /// timeout is extended to ``Config/authChallengeTimeout`` and the real response arrives later
    /// with the same id.
    /// - Throws: ``RemoteSignerError/signerError(message:)`` if the response carries an error,
    ///   ``RemoteSignerError/timedOut`` on timeout, or an encoding/transport error.
    func sendRequest(method: RemoteSignerMethod, params: [String]) async throws -> RemoteSignerResponse {
        try await ensureStarted()

        let request = RemoteSignerRequest(method: method, params: params)
        let event = try buildRequestEvent(request)
        let response = try await session.perform(
            event, key: request.id, state: method, timeout: config.requestTimeout)

        if let message = response.error, !response.isAuthChallenge {
            throw RemoteSignerError.signerError(message: message)
        }
        return response
    }

    private func buildRequestEvent(_ request: RemoteSignerRequest) throws -> Event {
        // The signer's pubkey must be known before any request can be addressed to it — always true
        // for a bunker session, and true for a nostrconnect session once awaitConnection() resolves.
        let signerPubkey = try requireSignerPubkey()
        do {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            let sealed = try SealedMessage.seal(json, for: signerPubkey, using: clientKeyPair)
            let unsigned = UnsignedEvent(
                pubkey: clientPublicKey,
                kind: .nostrConnect,
                rawTags: [["p", signerPubkey]],
                content: sealed.payload)
            return try signer.sign(unsigned)
        } catch {
            throw RemoteSignerError.requestEncodingFailed
        }
    }

    // MARK: - Incoming events

    private func handle(event: Event) async {
        // A client-initiated (nostrconnect://) session does not yet know the signer's pubkey: the
        // first valid response echoing the invitation secret both authenticates the signer and
        // reveals it. Route such events to the connection waiter instead of the request path.
        guard let signerPubkey else {
            handleConnectionCandidate(event)
            return
        }

        // The relay filter already restricts authors, but enforce it here too as defense in depth:
        // ignore anything that is not from the signer.
        guard event.pubkey == signerPubkey else { return }

        guard let content = try? SealedMessage(payload: event.content).open(from: event.pubkey, using: clientKeyPair),
            let response = try? JSONDecoder().decode(RemoteSignerResponse.self, from: Data(content.utf8))
        else {
            return
        }

        guard let method = await session.state(for: response.id) else { return }

        if response.isAuthChallenge, let error = response.error, let url = URL(string: error) {
            // Keep the request pending — the real response arrives later with the same id. Extend
            // its timeout so the user has time to authorize, and surface the challenge.
            await session.extendTimeout(for: response.id, to: config.authChallengeTimeout)

            let challenge = RemoteSignerAuthChallenge(url: url, method: method, requestID: response.id)
            for stream in authChallengeStreams.values {
                stream.yield(challenge)
            }
            return
        }

        await session.complete(response.id, with: response)
    }

    // MARK: - Client-initiated connection

    /// Waits for the signer to accept a `nostrconnect://` invitation and returns its discovered
    /// pubkey. Backs ``awaitConnection()``; see that method for the full contract.
    func discoverSigner() async throws -> String {
        try await ensureStarted()

        // Already discovered (e.g. a second call, or a bunker session): nothing to wait for.
        if let signerPubkey { return signerPubkey }

        // Only one waiter at a time; a concurrent caller would clobber the continuation.
        guard connectionWaiter == nil else {
            throw RemoteSignerError.connectionInProgress
        }

        let signerPubkey: String
        if let buffered = bufferedDiscovery {
            // A valid connect response already arrived while we were starting up.
            bufferedDiscovery = nil
            signerPubkey = buffered
        } else {
            let timeout = config.requestTimeout
            signerPubkey = try await withCheckedThrowingContinuation { continuation in
                connectionWaiter = continuation
                connectionTimeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    guard !Task.isCancelled else { return }
                    await self?.failConnection(with: .timedOut)
                }
            }
        }

        // Pin subsequent traffic to the now-known signer (defense in depth) and mark connected.
        self.signerPubkey = signerPubkey
        didConnect = true
        try? await session.subscribe(id: Self.responseSubscriptionID, filters: [responseFilter])
        return signerPubkey
    }

    /// Inspects an event received before the signer is known: if it decrypts to a response whose
    /// result echoes the expected invitation secret, it is the authentic connect acknowledgement, so
    /// resolve the waiter with the sender's pubkey. Anything else (including a mismatched secret from
    /// a spoofer) is ignored so the client keeps waiting for the correct response.
    private func handleConnectionCandidate(_ event: Event) {
        guard let expectedInvitationSecret else { return }

        guard let content = try? SealedMessage(payload: event.content).open(from: event.pubkey, using: clientKeyPair),
            let response = try? JSONDecoder().decode(RemoteSignerResponse.self, from: Data(content.utf8)),
            response.result == expectedInvitationSecret
        else {
            return
        }

        if connectionWaiter != nil {
            resolveConnection(with: event.pubkey)
        } else {
            // The waiter isn't registered yet (the response arrived between the subscription being
            // created and ``discoverSigner()`` suspending); hold the pubkey for it to pick up.
            bufferedDiscovery = event.pubkey
        }
    }

    /// Resolves the pending ``discoverSigner()`` waiter with the discovered signer pubkey.
    private func resolveConnection(with signerPubkey: String) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let waiter = connectionWaiter
        connectionWaiter = nil
        waiter?.resume(returning: signerPubkey)
    }

    /// Fails the pending ``discoverSigner()`` waiter (e.g. on timeout).
    private func failConnection(with error: RemoteSignerError) {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        let waiter = connectionWaiter
        connectionWaiter = nil
        waiter?.resume(throwing: error)
    }

    /// The signer's pubkey, or throws ``RemoteSignerError/notConnected`` if it is not yet known (a
    /// nostrconnect session before ``awaitConnection()`` resolves).
    private func requireSignerPubkey() throws -> String {
        guard let signerPubkey else { throw RemoteSignerError.notConnected }
        return signerPubkey
    }

    // MARK: - Commands support

    /// Sends a request, returning the required `result` string or throwing when it is absent.
    func performSingle(method: RemoteSignerMethod, params: [String]) async throws -> String {
        let response = try await sendRequest(method: method, params: params)
        guard let result = response.result else {
            throw RemoteSignerError.responseDecodingFailed
        }
        return result
    }

    /// The user's public key if it has already been fetched by ``userPublicKey()``.
    var userPublicKeyIfCached: String? {
        cachedUserPublicKey
    }

    /// Records the user's public key so later calls return it without another round-trip.
    func cacheUserPublicKey(_ pubkey: String) {
        cachedUserPublicKey = pubkey
    }

    // MARK: - Filters

    /// The subscription filter for incoming responses. It pins `authors` to the signer once known
    /// (a bunker session, or a nostrconnect session after discovery); before a nostrconnect signer
    /// is known it omits `authors` so the client can receive the connect response from any pubkey.
    private var responseFilter: Filter {
        Filter(authors: signerPubkey.map { [$0] }, kinds: [.nostrConnect], pubkeyReferences: [clientPublicKey])
    }

    // MARK: - Testing

    /// Whether the `connect` handshake has completed. Exposed for tests.
    var isConnectedForTesting: Bool {
        didConnect
    }

    /// Whether an ``awaitConnection()`` wait is currently suspended. Exposed for tests.
    var isAwaitingConnectionForTesting: Bool {
        connectionWaiter != nil
    }
}
