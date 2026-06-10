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

    /// The WebSocket task
    private var webSocketTask: URLSessionWebSocketTask?

    /// URL session for WebSocket connections
    private let urlSession: URLSession

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

    /// Continuations for async message receiving (supports multiple consumers)
    private var messageContinuations: [UUID: AsyncStream<RelayMessage>.Continuation] = [:]

    /// Continuation for connection state changes
    private var stateChangeContinuations: [UUID: AsyncStream<RelayConnectionState>.Continuation] = [:]

    /// Pending continuations waiting for OK response after publish,
    /// keyed by event id and then by a per-publish token so concurrent
    /// publishes of the same event don't clobber each other's waiters
    private var pendingPublishWaiters: [String: [UUID: AsyncThrowingStream<Void, Error>.Continuation]] = [:]

    public init(url: URL, urlSession: URLSession = .shared, config: RelayConnectionConfig = .default) {
        self.url = url
        self.urlSession = urlSession
        self.config = config
        self.currentReconnectDelay = config.initialReconnectDelay
    }

    public init(urlString: String, config: RelayConnectionConfig = .default) throws {
        guard let url = URL(string: urlString) else {
            throw NostrError.connectionFailed("Invalid URL: \(urlString)")
        }
        self.url = url
        self.urlSession = .shared
        self.config = config
        self.currentReconnectDelay = config.initialReconnectDelay
    }

    /// Connects to the relay
    public func connect() async throws {
        guard
            state == .disconnected || state == .failed("")
                || {
                    if case .failed = state { return true }
                    return false
                }()
        else { return }

        updateState(.connecting)

        var request = URLRequest(url: url)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.timeoutInterval = config.connectionTimeout

        let task = urlSession.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        let timeout = config.connectionTimeout

        // Verify connection with ping before marking as connected (with timeout)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        // sendPing can invoke its handler multiple times when the socket is
                        // cancelled/aborted (e.g. errno 53 "Software caused connection abort"),
                        // so guard the resume to fire exactly once.
                        let resumeGuard = ResumeOnceGuard()
                        task.sendPing { error in
                            guard resumeGuard.claim() else { return }
                            if let error = error {
                                continuation.resume(throwing: error)
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw NostrError.timeout
                }

                // Wait for either ping to succeed or timeout
                try await group.next()
                group.cancelAll()
            }
            updateState(.connected)
            resetReconnectState()
            startReceiving()
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
        updateState(.disconnected)
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
                    try await Task.sleep(for: .seconds(self.config.operationTimeout))
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
    /// Throws if the relay responds with accepted: false or if no OK is received within the operation timeout.
    public func publish(_ event: Event) async throws {
        guard state == .connected else {
            throw NostrError.notConnected
        }

        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, Error>.makeStream()
        pendingPublishWaiters[event.id, default: [:]][token] = continuation

        do {
            try await send(.event(event))
        } catch {
            removePublishWaiter(eventId: event.id, token: token)?.finish()
            throw error
        }

        defer {
            removePublishWaiter(eventId: event.id, token: token)?.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in stream {
                    return
                }
            }

            group.addTask {
                try await Task.sleep(for: .seconds(self.config.operationTimeout))
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

                    // Receive with timeout
                    let message = try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message.self) { group in
                        group.addTask {
                            try await task.receive()
                        }

                        group.addTask {
                            try await Task.sleep(for: .seconds(self.config.operationTimeout))
                            throw NostrError.timeout
                        }

                        guard let result = try await group.next() else {
                            group.cancelAll()
                            throw NostrError.timeout
                        }
                        group.cancelAll()
                        return result
                    }

                    switch message {
                    case .string(let text):
                        if let relayMessage = try? RelayMessage.parse(text) {
                            if case .ok(let eventId, let accepted, let message) = relayMessage {
                                for waiter in await self.removeAllPublishWaiters(eventId: eventId) {
                                    if accepted {
                                        waiter.finish()
                                    } else {
                                        waiter.finish(
                                            throwing: NostrError.relayError(
                                                "Relay rejected event \(eventId): \(message)"))
                                    }
                                }
                            }
                            await self.yieldToMessageContinuations(relayMessage)
                        }

                    case .data:
                        // Binary data not expected from Nostr relays
                        break

                    @unknown default:
                        break
                    }
                } catch {
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
