import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Manages a WebSocket connection to a single Nostr relay
public actor RelayConnection {
    /// The relay URL
    public let url: URL

    /// Current connection state
    public private(set) var state: RelayConnectionState = .disconnected

    /// Active subscriptions (subscription ID -> filters) for resubscription after reconnect
    private var subscriptions: [String: [Filter]] = [:]

    /// The active WebSocket transport
    private var webSocketTask: (any WebSocketSession)?

    /// Creates the WebSocket transport for each connection attempt
    private let webSocketFactory: any WebSocketSessionFactory

    /// Connection configuration
    public let config: RelayConnectionConfig

    /// Current reconnection attempt count
    private var reconnectAttempts: Int = 0

    /// Current reconnect delay
    private var currentReconnectDelay: TimeInterval = 1

    /// Whether reconnection is in progress
    private var isReconnecting: Bool = false

    /// Reconnection task
    private var reconnectTask: Task<Void, Never>?

    /// Keepalive ping task; non-nil only while the connection is believed healthy
    private var keepaliveTask: Task<Void, Never>?

    /// In-flight connection attempt, shared by concurrent connect() callers
    private var connectTask: Task<Void, Error>?

    /// Continuations for async message receiving (supports multiple consumers)
    private var messageContinuations: [UUID: AsyncStream<RelayMessage>.Continuation] = [:]

    /// Continuation for connection state changes
    private var stateChangeContinuations: [UUID: AsyncStream<RelayConnectionState>.Continuation] = [:]

    /// Pending continuations waiting for OK response after publish,
    /// keyed by event id and then by a per-publish token so concurrent
    /// publishes of the same event don't clobber each other's waiters
    private var pendingPublishWaiters: [String: [UUID: AsyncThrowingStream<Void, Error>.Continuation]] = [:]

    /// The most recent challenge received in an AUTH message from the relay (NIP-42).
    ///
    /// `nil` until the relay sends a challenge; replaced when the relay sends a
    /// newer one. A challenge is only valid for the WebSocket session that
    /// delivered it, so it is cleared whenever the connection is torn down or
    /// re-established.
    public private(set) var authenticationChallenge: String?

    /// The pubkeys this connection has successfully authenticated (NIP-42).
    ///
    /// A pubkey is added when the relay acknowledges its AUTH event with OK
    /// `true`. Authentication only lasts for the current WebSocket session, so
    /// the set is emptied whenever the connection is torn down or re-established.
    /// Multiple pubkeys can be authenticated on one connection by calling
    /// ``authenticate(with:)`` once per identity.
    public private(set) var authenticatedPubkeys: Set<String> = []

    /// Pubkeys of in-flight AUTH events keyed by event id, so the receive loop
    /// can mark them authenticated the moment the relay's OK arrives. An entry
    /// lives only as long as its ``authenticate(with:)`` call: a failed or
    /// cancelled call removes it, so a late OK after a reported failure cannot
    /// silently flip the connection to authenticated.
    private var pendingAuthentications: [String: String] = [:]

    /// Whether at least one pubkey is authenticated on this connection (NIP-42).
    public var isAuthenticated: Bool {
        !authenticatedPubkeys.isEmpty
    }

    public init(url: URL, urlSession: URLSession = .shared, config: RelayConnectionConfig = .default) {
        self.init(
            url: url,
            webSocketFactory: URLSessionWebSocketFactory(urlSession: urlSession),
            config: config
        )
    }

    public init(urlString: String, config: RelayConnectionConfig = .default) throws {
        guard let url = URL(string: urlString) else {
            throw NostrError.connectionFailed("Invalid URL: \(urlString)")
        }
        self.init(url: url, config: config)
    }

    /// Designated initializer shared by the public initializers and by tests, which inject a
    /// fake ``WebSocketSessionFactory`` to drive the connection state machine without a network.
    init(
        url: URL,
        webSocketFactory: any WebSocketSessionFactory,
        config: RelayConnectionConfig = .default
    ) {
        self.url = url
        self.webSocketFactory = webSocketFactory
        self.config = config
        self.currentReconnectDelay = config.initialReconnectDelay
    }

    /// Connects to the relay.
    ///
    /// Concurrent callers share a single in-flight attempt: a caller arriving while
    /// another task is still connecting awaits that attempt's real outcome instead
    /// of returning early with the socket not yet established. Every sharer sees
    /// the same success or failure.
    public func connect() async throws {
        if state == .connected { return }

        if let existing = connectTask {
            try await existing.value
            return
        }

        guard
            state == .disconnected
                || {
                    if case .failed = state { return true }
                    return false
                }()
        else { return }

        // Unstructured on purpose: one caller's cancellation must not abort the
        // attempt other callers are waiting on. The slot is cleared inside the
        // task itself so it lives exactly as long as the attempt — clearing it
        // from the caller would be tied to the caller's lifetime instead.
        let task = Task {
            defer { connectTask = nil }
            try await performConnect()
        }
        connectTask = task
        try await task.value
    }

    /// Establishes the WebSocket connection and verifies it with a ping.
    private func performConnect() async throws {
        updateState(.connecting)

        // NIP-42 challenges and authentications are scoped to a WebSocket
        // session; a fresh socket starts unauthenticated with no challenge.
        resetAuthenticationState()

        var request = URLRequest(url: url)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.timeoutInterval = config.connectionTimeout

        let task = webSocketFactory.makeWebSocket(with: request)
        webSocketTask = task
        task.resume()

        // Verify connection with ping before marking as connected (with timeout)
        do {
            try await Self.pingSocket(task, timeout: config.connectionTimeout)
            updateState(.connected)
            resetReconnectState()
            startReceiving()
            startKeepalive()
        } catch {
            updateState(.failed(error.localizedDescription))
            webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
            webSocketTask = nil
            throw NostrError.connectionFailed(error.localizedDescription)
        }
    }

    /// Disconnects from the relay
    public func disconnect() {
        // Cancel any pending reconnection
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        keepaliveTask?.cancel()
        keepaliveTask = nil

        guard state == .connected || state == .connecting else {
            updateState(.disconnected)
            return
        }

        updateState(.disconnecting)
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        subscriptions.removeAll()
        for waiters in pendingPublishWaiters.values {
            for waiter in waiters.values {
                waiter.finish(throwing: NostrError.notConnected)
            }
        }
        pendingPublishWaiters.removeAll()
        resetAuthenticationState()
        updateState(.disconnected)
    }

    /// Clears all NIP-42 state. Challenges and authenticated pubkeys are only
    /// valid for a single WebSocket session, so this runs on every teardown
    /// and before every (re)connection attempt.
    private func resetAuthenticationState() {
        authenticationChallenge = nil
        authenticatedPubkeys.removeAll()
        pendingAuthentications.removeAll()
    }

    /// Sends a client message to the relay
    public func send(_ message: ClientMessage) async throws {
        // Reconnect if not connected
        if state != .connected {
            try await connect()
        }

        guard let task = webSocketTask else {
            throw NostrError.notConnected
        }

        let text = try message.serialize()
        do {
            // Send with timeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await task.send(.string(text))
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(self.config.sendTimeout))
                    throw NostrError.timeout
                }

                try await group.next()
                group.cancelAll()
            }
        } catch {
            // Update state on send failure
            updateState(.failed(error.localizedDescription))
            scheduleReconnectIfNeeded()
            if let nostrError = error as? NostrError {
                throw nostrError
            } else {
                throw NostrError.notConnected
            }
        }

        // Track subscription state
        switch message {
        case .request(let subscriptionId, let filters):
            subscriptions[subscriptionId] = filters
        case .close(let subscriptionId):
            subscriptions.removeValue(forKey: subscriptionId)
        default:
            break
        }
    }

    /// Publishes an event to the relay and waits for OK from the relay.
    ///
    /// Fails fast with ``NostrError/notConnected`` when the connection is not established —
    /// the publish path never connects inline, so a dead relay fails immediately instead of
    /// spending up to `connectionTimeout` on a reconnect attempt. Reconnection is owned by
    /// the background auto-reconnect with exponential backoff.
    ///
    /// Throws if the relay responds with accepted: false or if no OK is received within the publish ack timeout.
    public func publish(_ event: Event) async throws {
        guard state == .connected else {
            throw NostrError.notConnected
        }

        do {
            try await sendAndAwaitOK(.event(event), eventId: event.id)
        } catch let rejection as EventRejection {
            throw NostrError.relayError("Relay rejected event \(rejection.eventId): \(rejection.message)")
        }
    }

    /// Authenticates this connection with a pre-signed kind-22242 event and
    /// waits for the relay's OK (NIP-42).
    ///
    /// Most callers should prefer ``authenticate(using:)``, which builds and
    /// signs the event from the stored ``authenticationChallenge``. Use this
    /// overload when the event is produced elsewhere, e.g. by a remote signer.
    ///
    /// On success the event's pubkey is added to ``authenticatedPubkeys`` and
    /// the relay treats it as authenticated for the rest of the session.
    ///
    /// - Parameter event: A signed ``Event/Kind/clientAuthentication`` event
    ///   carrying `relay` and `challenge` tags.
    /// - Throws: ``NostrError/authenticationFailed(_:)`` when the event is not
    ///   kind 22242 or the relay rejects it, ``NostrError/notConnected`` when
    ///   the connection is not established, or ``NostrError/timeout`` when no
    ///   OK arrives within ``RelayConnectionConfig/publishAckTimeout``.
    public func authenticate(with event: Event) async throws {
        guard event.kind == .clientAuthentication else {
            throw NostrError.authenticationFailed(
                "An authentication event must be kind \(Event.Kind.clientAuthentication), got kind \(event.kind)")
        }
        guard state == .connected else {
            throw NostrError.notConnected
        }

        // Recorded before sending so the receive loop can mark the pubkey as
        // authenticated the moment the OK arrives while this call is in flight.
        pendingAuthentications[event.id] = event.pubkey

        do {
            try await sendAndAwaitOK(.auth(event), eventId: event.id)
        } catch let rejection as EventRejection {
            throw NostrError.authenticationFailed(rejection.message)
        } catch {
            // Once a failure (timeout, send error, cancellation) is reported to
            // the caller, a late OK must not silently flip the connection to
            // authenticated — drop the pending entry along with the error.
            pendingAuthentications.removeValue(forKey: event.id)
            throw error
        }
    }

    /// Builds, signs, and sends the answer to the relay's most recent AUTH
    /// challenge, then waits for the relay's OK (NIP-42).
    ///
    /// - Parameter signer: The signer for the identity to authenticate.
    /// - Throws: ``NostrError/authenticationFailed(_:)`` when the relay has not
    ///   sent a challenge yet or rejects the authentication, plus everything
    ///   ``authenticate(with:)`` throws.
    public func authenticate(using signer: EventSigner) async throws {
        guard let challenge = authenticationChallenge else {
            throw NostrError.authenticationFailed("The relay has not sent an AUTH challenge")
        }
        let event = try signer.signClientAuthentication(relayURL: url, challenge: challenge)
        try await authenticate(with: event)
    }

    /// Sends `message` and suspends until the relay's OK for `eventId` arrives,
    /// bounded by ``RelayConnectionConfig/publishAckTimeout``. Shared by
    /// ``publish(_:)`` and ``authenticate(with:)``.
    ///
    /// - Throws: ``EventRejection`` when the relay answers OK `false`,
    ///   ``NostrError/timeout`` when no OK arrives in time.
    private func sendAndAwaitOK(_ message: ClientMessage, eventId: String) async throws {
        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        pendingPublishWaiters[eventId, default: [:]][token] = continuation

        do {
            try await send(message)
        } catch {
            removePublishWaiter(eventId: eventId, token: token)?.finish()
            throw error
        }

        defer {
            removePublishWaiter(eventId: eventId, token: token)?.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in stream {
                    return
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(self.config.publishAckTimeout))
                throw NostrError.timeout
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// Removes and returns a single publish waiter (called from within the actor).
    @discardableResult
    private func removePublishWaiter(eventId: String, token: UUID) -> AsyncThrowingStream<Void, Error>.Continuation? {
        guard var waiters = pendingPublishWaiters[eventId] else { return nil }
        let continuation = waiters.removeValue(forKey: token)
        if waiters.isEmpty {
            pendingPublishWaiters.removeValue(forKey: eventId)
        } else {
            pendingPublishWaiters[eventId] = waiters
        }
        return continuation
    }

    /// Removes and returns all publish waiters for an event id —
    /// one OK from the relay satisfies every pending publish of that event.
    private func removeAllPublishWaiters(eventId: String) -> [AsyncThrowingStream<Void, Error>.Continuation] {
        guard let waiters = pendingPublishWaiters.removeValue(forKey: eventId) else { return [] }
        return Array(waiters.values)
    }

    /// Yields the relay message to all active message continuations (actor-isolated).
    private func yieldToMessageContinuations(_ message: RelayMessage) {
        for continuation in messageContinuations.values {
            continuation.yield(message)
        }
    }

    /// Subscribes to events matching the given filters
    public func subscribe(subscriptionId: String, filters: [Filter]) async throws {
        try await send(.request(subscriptionId: subscriptionId, filters: filters))
    }

    /// Unsubscribes from a subscription
    public func unsubscribe(subscriptionId: String) async throws {
        try await send(.close(subscriptionId: subscriptionId))
    }

    /// Returns an async stream of messages from this relay
    /// Each call creates a new stream that receives all future messages
    public func messages() -> AsyncStream<RelayMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            self.messageContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeMessageContinuation(id: id)
                }
            }
        }
    }

    /// Returns an async stream of connection state changes
    public func stateChanges() -> AsyncStream<RelayConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateChangeContinuations[id] = continuation
            // Emit current state immediately
            continuation.yield(self.state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeStateContinuation(id: id)
                }
            }
        }
    }

    /// Removes a message continuation by ID
    private func removeMessageContinuation(id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    /// Removes a state continuation by ID
    private func removeStateContinuation(id: UUID) {
        stateChangeContinuations.removeValue(forKey: id)
    }

    /// Updates state and notifies listeners
    private func updateState(_ newState: RelayConnectionState) {
        state = newState
        for continuation in stateChangeContinuations.values {
            continuation.yield(newState)
        }
    }

    /// Checks if a subscription is active
    public func hasSubscription(_ subscriptionId: String) -> Bool {
        subscriptions[subscriptionId] != nil
    }

    /// Returns all active subscription IDs
    public func activeSubscriptions() -> Set<String> {
        Set(subscriptions.keys)
    }

    // MARK: - Private Methods

    private func startReceiving() {
        Task {
            while state == .connected {
                do {
                    guard let task = webSocketTask else { break }

                    // Wait indefinitely: liveness is detected by the keepalive ping,
                    // not by how often the relay has messages to deliver.
                    let message = try await task.receive()

                    switch message {
                    case .string(let text):
                        if let relayMessage = try? RelayMessage.parse(text) {
                            switch relayMessage {
                            case .ok(let eventId, let accepted, let message):
                                // Settle a pending NIP-42 authentication for this event id.
                                // Removed on both outcomes; only an accepted AUTH marks the
                                // pubkey as authenticated.
                                if let pubkey = pendingAuthentications.removeValue(forKey: eventId),
                                    accepted
                                {
                                    authenticatedPubkeys.insert(pubkey)
                                }
                                for waiter in removeAllPublishWaiters(eventId: eventId) {
                                    if accepted {
                                        waiter.finish()
                                    } else {
                                        waiter.finish(
                                            throwing: EventRejection(eventId: eventId, message: message))
                                    }
                                }
                            case .auth(let challenge):
                                authenticationChallenge = challenge
                            default:
                                break
                            }
                            yieldToMessageContinuations(relayMessage)
                        }

                    case .data:
                        // Binary data not expected from Nostr relays
                        break

                    @unknown default:
                        break
                    }
                } catch {
                    // The keepalive has no work to do once the receive loop is gone.
                    keepaliveTask?.cancel()
                    keepaliveTask = nil
                    if state == .connected {
                        updateState(.failed(error.localizedDescription))
                        scheduleReconnectIfNeeded()
                    }
                    break
                }
            }

            // Don't finish continuations if we're reconnecting
            if !isReconnecting {
                for continuation in messageContinuations.values {
                    continuation.finish()
                }
                messageContinuations.removeAll()
            }
        }
    }

    // MARK: - Keepalive

    /// Sends a WebSocket ping and waits for the pong, bounded by `timeout`.
    ///
    /// `sendPing` can invoke its handler multiple times when the socket is
    /// cancelled/aborted (e.g. errno 53 "Software caused connection abort"), the
    /// timeout watchdog races the handler, and task cancellation races both — so
    /// ``ResumeOnceGuard`` arbitrates every resume site to fire exactly once.
    /// Cancelling the waiting task resumes immediately with `CancellationError`
    /// instead of staying suspended until the pong or the watchdog fires.
    private static func pingSocket(_ task: any WebSocketSession, timeout: TimeInterval) async throws {
        let resumeGuard = ResumeOnceGuard()
        let cancellationBox = PingCancellationBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard cancellationBox.register(continuation) else {
                    // The task was cancelled before the wait began; onCancel found
                    // nothing to resume, so it is this path's job.
                    guard resumeGuard.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let watchdog = Task {
                    try? await Task.sleep(for: .seconds(timeout))
                    guard resumeGuard.claim() else { return }
                    continuation.resume(throwing: NostrError.timeout)
                }
                task.sendPing { error in
                    guard resumeGuard.claim() else { return }
                    watchdog.cancel()
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            guard let continuation = cancellationBox.cancel() else { return }
            guard resumeGuard.claim() else { return }
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Starts the periodic keepalive ping loop for the current connection.
    /// Replaces any previous keepalive so at most one runs per connection.
    private func startKeepalive() {
        keepaliveTask?.cancel()
        let interval = config.pingInterval
        let pongTimeout = config.connectionTimeout
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                // Re-check after every suspension: the connection may have been
                // disconnected, failed, or replaced while this task slept.
                guard !Task.isCancelled, state == .connected, let task = webSocketTask else { return }
                do {
                    try await Self.pingSocket(task, timeout: pongTimeout)
                } catch {
                    // A ping that raced a deliberate disconnect or reconnect is not a failure.
                    guard !Task.isCancelled, state == .connected else { return }
                    handleKeepaliveFailure(error)
                    return
                }
            }
        }
    }

    /// Tears the connection down after a failed keepalive ping and schedules a reconnect.
    private func handleKeepaliveFailure(_ error: Error) {
        updateState(.failed(error.localizedDescription))
        // Cancel the socket so the receive loop's pending receive() exits promptly.
        webSocketTask?.cancel(with: .abnormalClosure, reason: nil)
        webSocketTask = nil
        scheduleReconnectIfNeeded()
    }

    // MARK: - Reconnection Logic

    /// Resets reconnect state after successful connection
    private func resetReconnectState() {
        reconnectAttempts = 0
        currentReconnectDelay = config.initialReconnectDelay
        isReconnecting = false
    }

    /// Schedules a reconnection attempt if auto-reconnect is enabled
    private func scheduleReconnectIfNeeded() {
        guard config.autoReconnect else { return }
        guard !isReconnecting else { return }

        // Check if we've exceeded max attempts
        if config.maxReconnectAttempts > 0 && reconnectAttempts >= config.maxReconnectAttempts {
            return
        }

        isReconnecting = true

        reconnectTask = Task {
            // Wait with exponential backoff
            let delay = currentReconnectDelay
            try? await Task.sleep(for: .seconds(delay))

            guard !Task.isCancelled else { return }

            // Calculate next delay with exponential backoff
            currentReconnectDelay = min(
                currentReconnectDelay * config.reconnectBackoffMultiplier,
                config.maxReconnectDelay
            )
            reconnectAttempts += 1

            do {
                try await connect()
                // Resubscribe to all active subscriptions after reconnection
                await resubscribeAll()
            } catch {
                // Connection failed, schedule another attempt
                isReconnecting = false
                scheduleReconnectIfNeeded()
            }
        }
    }

    /// Resubscribes to all active subscriptions after reconnection
    private func resubscribeAll() async {
        let currentSubscriptions = subscriptions
        for (subscriptionId, filters) in currentSubscriptions {
            do {
                try await subscribe(subscriptionId: subscriptionId, filters: filters)
            } catch {
                // Continue with other subscriptions even if one fails
            }
        }
    }

    /// Manually trigger a reconnection attempt
    public func reconnect() async throws {
        disconnect()
        resetReconnectState()
        try await connect()
    }
}

// MARK: - Equatable
extension RelayConnection: Equatable {
    public static func == (lhs: RelayConnection, rhs: RelayConnection) -> Bool {
        lhs.url == rhs.url
    }
}

// MARK: - Hashable
extension RelayConnection: Hashable {
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - NIP-11
extension RelayConnection {
    /// Fetches the NIP-11 Relay Information Document for this relay.
    ///
    /// This performs an HTTP GET request to the relay's URL (with the scheme
    /// converted from `wss://`/`ws://` to `https://`/`http://`) and works
    /// independently of the WebSocket connection state.
    ///
    /// - Parameter urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The decoded ``RelayInformation``.
    /// - Throws: ``RelayInformation/FetchError`` on URL, network, or
    ///   decoding errors.
    public nonisolated func fetchInformation(urlSession: URLSession = .shared) async throws -> RelayInformation {
        try await RelayInformation.fetch(from: url, urlSession: urlSession)
    }
}

// MARK: - OK Rejection

/// The relay answered an EVENT or AUTH with OK `false`.
///
/// Internal carrier between the receive loop and the operations awaiting the
/// OK: ``RelayConnection/publish(_:)`` rewraps it as
/// ``NostrError/relayError(_:)`` and ``RelayConnection/authenticate(with:)``
/// as ``NostrError/authenticationFailed(_:)``, so each surfaces an error in
/// its own vocabulary from the same wire response.
struct EventRejection: Error, Sendable {
    /// The id of the rejected event.
    let eventId: String

    /// The relay's status string, e.g. `"restricted: not allowed to write"`.
    let message: String
}

// MARK: - Ping Cancellation Support

/// Hands the ping continuation from the suspension point to the task-cancellation
/// handler, closing the race where cancellation fires before the continuation exists.
///
/// `register` returns `false` when cancellation already happened, telling the caller
/// to resume the continuation itself; `cancel` marks the box cancelled and takes the
/// continuation if one was registered. Exactly-once resumption across the pong
/// handler, the watchdog, and cancellation remains the job of ``ResumeOnceGuard``.
private final class PingCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var isCancelled = false

    /// Stores the continuation for a later `cancel`; returns `false` if the task
    /// was already cancelled (the continuation is not stored).
    func register(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { return false }
        self.continuation = continuation
        return true
    }

    /// Marks the box cancelled and returns the registered continuation, if any.
    func cancel() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}
