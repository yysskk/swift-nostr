import Foundation
public import NostrCore

/// A session with a NIP-46 remote signer (a "bunker"), driven over a relay transport.
///
/// The user's private key never leaves the signer. This actor holds a separate *client* identity,
/// encrypts a request to the signer, signs a kind-24133 event with the client key, sends it to the
/// signer's relays, and awaits the matching response — correlated by the `id` field inside the
/// decrypted JSON body (not by any event tag). Build one from a signer-issued ``BunkerURI`` and call
/// the typed commands (see `RemoteSigner+Commands`).
///
/// ### The connect handshake
/// The first request is always `connect`, presenting the bunker secret when the token carries one.
/// Commands call ``connect()`` automatically on first use.
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

    private let transport: any RemoteSignerTransport
    private let config: Config
    private let clientKeyPair: KeyPair
    private let signer: EventSigner
    private let secret: String?

    /// The local client identity's public key (hex). The user's key never leaves the signer.
    public nonisolated let clientPublicKey: String

    private let signerPubkey: String

    private var startTask: Task<Void, Error>?
    private var isStarted: Bool { startTask != nil }
    private var didConnect = false
    private var readerTask: Task<Void, Never>?

    /// In-flight requests keyed by the JSON request `id` (echoed back in the response's `id`).
    private var pending: [String: PendingRequest] = [:]
    /// Open auth-challenge streams, keyed so each can deregister on termination.
    private var authChallengeStreams: [UUID: AsyncStream<RemoteSignerAuthChallenge>.Continuation] = [:]
    /// The user's public key (`get_public_key`), cached after the first fetch.
    private var cachedUserPublicKey: String?

    /// Creates a session from a signer-issued `bunker://` token.
    /// - Parameters:
    ///   - bunker: The parsed token.
    ///   - clientKeyPair: The local client identity; a fresh random keypair by default. Pass a
    ///     persisted one to resume an authorized session.
    ///   - transport: The relay transport. Defaults to a ``RelayConnectionTransport`` over the
    ///     token's relays; inject a custom one (e.g. for tests).
    ///   - config: Session behavior.
    /// - Throws: An error if `clientKeyPair` is `nil` and a fresh keypair cannot be generated.
    public init(
        bunker: BunkerURI,
        clientKeyPair: KeyPair? = nil,
        transport: (any RemoteSignerTransport)? = nil,
        config: Config = Config()
    ) throws {
        let keyPair = try clientKeyPair ?? KeyPair()
        self.clientKeyPair = keyPair
        self.signer = EventSigner(keyPair: keyPair)
        self.clientPublicKey = keyPair.publicKeyHex
        self.signerPubkey = bunker.remoteSignerPubkey
        self.secret = bunker.secret
        self.config = config
        self.transport = transport ?? RelayConnectionTransport(relayURLs: bunker.relays)
    }

    /// The remote signer's public key (hex) — known immediately for a bunker session, and not
    /// necessarily the user's key (see ``userPublicKey()``).
    public var remoteSignerPubkey: String {
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
        if isStarted {
            _ = try? await sendRequest(method: .logout, params: [])
        }
        await disconnect()
    }

    /// Disconnects without notifying the signer, failing any in-flight requests with
    /// ``RemoteSignerError/notConnected`` and ending the auth-challenge streams.
    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        startTask?.cancel()
        startTask = nil
        didConnect = false

        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: RemoteSignerError.notConnected)
        }
        pending.removeAll()

        for stream in authChallengeStreams.values {
            stream.finish()
        }
        authChallengeStreams.removeAll()

        await transport.disconnect()
    }

    private func ensureStarted() async throws {
        // Track the in-flight setup as a shared task so a concurrent caller on first use awaits the
        // same connect/subscribe work, rather than racing past a bool guard and sending before the
        // transport is connected and the response subscription/reader task exist.
        if let startTask {
            try await startTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performStart()
        }
        startTask = task
        do {
            try await task.value
        } catch {
            // Clear on failure so a later attempt can retry the setup.
            startTask = nil
            throw error
        }
    }

    /// Connects the transport, subscribes for responses, and starts the reader task. Runs once per
    /// session via the shared ``startTask``.
    private func performStart() async throws {
        try await transport.connect()
        // Subscribe before sending anything so a response delivered during the subscribe
        // round-trip is not missed.
        try await transport.subscribe(id: Self.responseSubscriptionID, filters: [responseFilter])
        let events = await transport.events()
        readerTask = Task { [weak self] in
            for await event in events {
                await self?.handle(event: event)
            }
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

        let (stream, continuation) = AsyncThrowingStream<RemoteSignerResponse, Error>.makeStream()
        let timeoutTask = makeTimeoutTask(requestID: request.id, timeout: config.requestTimeout)
        pending[request.id] = PendingRequest(
            method: method, continuation: continuation, timeoutTask: timeoutTask)

        defer {
            if let removed = pending.removeValue(forKey: request.id) {
                removed.timeoutTask?.cancel()
            }
        }

        try await transport.send(event)

        for try await response in stream {
            if let message = response.error, !response.isAuthChallenge {
                throw RemoteSignerError.signerError(message: message)
            }
            return response
        }
        throw RemoteSignerError.timedOut
    }

    /// A task that fails the pending request with the given `id` after `timeout` seconds.
    private func makeTimeoutTask(requestID: String, timeout: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.timeoutRequest(requestID)
        }
    }

    private func timeoutRequest(_ requestID: String) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        request.continuation.finish(throwing: RemoteSignerError.timedOut)
    }

    private func buildRequestEvent(_ request: RemoteSignerRequest) throws -> Event {
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

    private func handle(event: Event) {
        // The relay filter already restricts authors, but enforce it here too as defense in depth:
        // ignore anything that is not from the signer.
        guard event.pubkey == signerPubkey else { return }

        guard let content = try? SealedMessage(payload: event.content).open(from: event.pubkey, using: clientKeyPair),
            let response = try? JSONDecoder().decode(RemoteSignerResponse.self, from: Data(content.utf8))
        else {
            return
        }

        guard let request = pending[response.id] else { return }

        if response.isAuthChallenge, let error = response.error, let url = URL(string: error) {
            // Keep the request pending — the real response arrives later with the same id. Extend
            // its timeout so the user has time to authorize, and surface the challenge.
            request.timeoutTask?.cancel()
            var updated = request
            updated.timeoutTask = makeTimeoutTask(requestID: response.id, timeout: config.authChallengeTimeout)
            pending[response.id] = updated

            let challenge = RemoteSignerAuthChallenge(url: url, method: request.method, requestID: response.id)
            for stream in authChallengeStreams.values {
                stream.yield(challenge)
            }
            return
        }

        pending.removeValue(forKey: response.id)
        request.timeoutTask?.cancel()
        request.continuation.yield(response)
        request.continuation.finish()
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

    private var responseFilter: Filter {
        Filter(authors: [signerPubkey], kinds: [.nostrConnect], pubkeyReferences: [clientPublicKey])
    }

    // MARK: - Testing

    /// Whether the `connect` handshake has completed. Exposed for tests.
    var isConnectedForTesting: Bool {
        didConnect
    }
}

/// State for an in-flight request awaiting its response.
private struct PendingRequest {
    /// The method whose request this is, used to label an `auth_url` challenge.
    let method: RemoteSignerMethod
    let continuation: AsyncThrowingStream<RemoteSignerResponse, Error>.Continuation
    /// The task that fails the request on timeout; replaced with a longer one on an `auth_url`
    /// challenge, and cancelled once the request resolves.
    var timeoutTask: Task<Void, Never>?
}
