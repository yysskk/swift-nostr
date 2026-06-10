import Foundation

/// Manages connections to multiple Nostr relays
public actor RelayPool {
    /// All relay connections
    private var relays: [URL: RelayConnection] = [:]

    /// Subscription handlers by subscription ID
    private var subscriptionHandlers: [String: @Sendable (RelaySubscriptionMessage) async -> Void] = [:]

    /// Pool configuration
    public let config: RelayPoolConfig

    /// Event deduplication cache with timestamps
    private var eventCache: [String: Date] = [:]

    /// Last cache cleanup time
    private var lastCacheCleanup: Date = Date()

    /// Message listener tasks for subscriptions (keyed by subscription ID)
    private var subscriptionTasks: [String: [Task<Void, Never>]] = [:]

    public init(config: RelayPoolConfig = .default) {
        self.config = config
    }

    /// Adds a relay to the pool
    @discardableResult
    public func addRelay(url: URL, config: RelayConnectionConfig? = nil) -> RelayConnection {
        if let existing = relays[url] {
            return existing
        }
        let connection = RelayConnection(url: url, config: config ?? self.config.defaultRelayConfig)
        relays[url] = connection
        return connection
    }

    /// Adds a relay to the pool by URL string
    @discardableResult
    public func addRelay(urlString: String, config: RelayConnectionConfig? = nil) throws -> RelayConnection {
        guard let url = URL(string: urlString) else {
            throw NostrError.connectionFailed("Invalid URL: \(urlString)")
        }
        return addRelay(url: url, config: config)
    }

    /// Removes a relay from the pool
    public func removeRelay(url: URL) async {
        if let connection = relays[url] {
            await connection.disconnect()
            relays.removeValue(forKey: url)
        }
    }

    /// Connects to all relays in the pool.
    /// Tolerates partial failures - succeeds if at least one relay connects.
    /// - Returns: The number of successfully connected relays
    /// - Throws: Only if all relays fail to connect
    @discardableResult
    public func connectAll() async throws -> Int {
        var successCount = 0

        await withTaskGroup(of: Bool.self) { group in
            for connection in relays.values {
                group.addTask {
                    do {
                        try await connection.connect()
                        return true
                    } catch {
                        return false
                    }
                }
            }

            for await success in group {
                if success {
                    successCount += 1
                }
            }
        }

        if successCount == 0 && !relays.isEmpty {
            throw NostrError.connectionFailed("All relays failed to connect")
        }

        return successCount
    }

    /// Disconnects from all relays in the pool
    public func disconnectAll() async {
        // Cancel all subscription listener tasks
        for tasks in subscriptionTasks.values {
            for task in tasks {
                task.cancel()
            }
        }
        subscriptionTasks.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for connection in relays.values {
                group.addTask {
                    await connection.disconnect()
                }
            }
        }
    }

    /// Publishes an event to connected relays.
    /// By default broadcasts to all relays; pass `relayURLs` to target a subset (NIP-65 outbox routing).
    /// Succeeds if at least one targeted relay accepts the event.
    public func publish(_ event: Event, to relayURLs: Set<URL>? = nil) async throws {
        var successCount = 0
        var lastError: Error?

        await withTaskGroup(of: Result<Void, Error>.self) { group in
            for connection in targetConnections(relayURLs) {
                group.addTask {
                    do {
                        try await connection.publish(event)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }

            for await result in group {
                switch result {
                case .success:
                    successCount += 1
                case .failure(let error):
                    lastError = error
                }
            }
        }

        // Succeed if at least one relay accepted the event
        if successCount == 0, let error = lastError {
            throw error
        }
    }

    /// Subscribes to events on all relays.
    /// Tolerates partial failures - succeeds if at least one relay accepts the subscription.
    /// Events are deduplicated across relays.
    /// - Returns: The number of relays that successfully subscribed
    /// - Throws: Only if all relays fail to subscribe
    @discardableResult
    public func subscribe(
        subscriptionId: String,
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        handler: @escaping @Sendable (RelayMessage) -> Void
    ) async throws -> Int {
        let successfulRelayURLs = try await subscribeWithRelayContext(
            subscriptionId: subscriptionId,
            filters: filters,
            to: relayURLs
        ) { relayMessage in
            handler(relayMessage.message)
        }

        return successfulRelayURLs.count
    }

    @discardableResult
    func subscribeWithRelayContext(
        subscriptionId: String,
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        handler: @escaping @Sendable (RelaySubscriptionMessage) async -> Void
    ) async throws -> Set<URL> {
        subscriptionHandlers[subscriptionId] = handler

        // Start listening for messages BEFORE sending subscription request
        // This ensures we don't miss any events that arrive immediately after subscribing
        var tasks: [Task<Void, Never>] = []
        for connection in targetConnections(relayURLs) {
            let task = Task {
                for await message in await connection.messages() {
                    guard !Task.isCancelled else { break }
                    let relayURL = connection.url
                    switch message {
                    case .event(let subId, let event) where subId == subscriptionId:
                        // Deduplicate events across relays
                        let isDuplicate = self.isDuplicateEvent(eventId: event.id)
                        if !isDuplicate {
                            self.markEventAsSeen(eventId: event.id)
                            if let currentHandler = self.subscriptionHandlers[subscriptionId] {
                                await currentHandler(
                                    RelaySubscriptionMessage(
                                        relayURL: relayURL,
                                        message: message
                                    )
                                )
                            }
                        }
                    case .endOfStoredEvents(let subId) where subId == subscriptionId:
                        if let currentHandler = self.subscriptionHandlers[subscriptionId] {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    case .closed(let subId, _) where subId == subscriptionId:
                        if let currentHandler = self.subscriptionHandlers[subscriptionId] {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    case .notice, .auth:
                        if let currentHandler = self.subscriptionHandlers[subscriptionId] {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    default:
                        break
                    }
                }
            }
            tasks.append(task)
        }
        subscriptionTasks[subscriptionId] = tasks

        // Yield to allow message-stream tasks to start before subscribing
        await Task.yield()

        // Now send subscription requests to all relays, tolerating failures
        var successfulRelayURLs: Set<URL> = []

        await withTaskGroup(of: URL?.self) { group in
            for connection in targetConnections(relayURLs) {
                group.addTask {
                    do {
                        try await connection.subscribe(subscriptionId: subscriptionId, filters: filters)
                        return connection.url
                    } catch {
                        return nil
                    }
                }
            }

            for await relayURL in group {
                if let relayURL {
                    successfulRelayURLs.insert(relayURL)
                }
            }
        }

        if successfulRelayURLs.isEmpty && !targetConnections(relayURLs).isEmpty {
            throw NostrError.relayError("Failed to subscribe on any relay")
        }

        return successfulRelayURLs
    }

    /// Unsubscribes from a subscription on all relays.
    /// Tolerates partial failures - best effort unsubscription.
    public func unsubscribe(subscriptionId: String) async {
        subscriptionHandlers.removeValue(forKey: subscriptionId)

        if let tasks = subscriptionTasks.removeValue(forKey: subscriptionId) {
            for task in tasks {
                task.cancel()
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for connection in relays.values {
                group.addTask {
                    try? await connection.unsubscribe(subscriptionId: subscriptionId)
                }
            }
        }
    }

    /// Returns all relay connections
    public var connections: [RelayConnection] {
        Array(relays.values)
    }

    /// Returns the relay connection for a given URL
    public func relay(for url: URL) -> RelayConnection? {
        relays[url]
    }

    /// Resolves the connections to target for a routed operation.
    /// `nil` targets all relays in the pool (the default broadcast behavior);
    /// a non-nil set targets only those URLs currently present in the pool.
    func targetConnections(_ relayURLs: Set<URL>?) -> [RelayConnection] {
        guard let relayURLs else {
            return Array(relays.values)
        }
        return relayURLs.compactMap { relays[$0] }
    }

    /// Returns the number of relays in the pool
    public var count: Int {
        relays.count
    }

    /// Returns the number of connected relays
    public func connectedCount() async -> Int {
        var count = 0
        for connection in relays.values {
            if await connection.state == .connected {
                count += 1
            }
        }
        return count
    }
}

// MARK: - Convenience Methods
extension RelayPool {
    /// Adds multiple relays from URL strings
    public func addRelays(_ urlStrings: [String]) throws {
        for urlString in urlStrings {
            _ = try addRelay(urlString: urlString)
        }
    }
}

// MARK: - Event Deduplication
extension RelayPool {
    /// Checks if an event has already been seen
    private func isDuplicateEvent(eventId: String) -> Bool {
        cleanupCacheIfNeeded()
        return eventCache[eventId] != nil
    }

    /// Marks an event as seen
    private func markEventAsSeen(eventId: String) {
        cleanupCacheIfNeeded()
        eventCache[eventId] = Date()
    }

    /// Cleans up expired entries from the cache
    private func cleanupCacheIfNeeded() {
        let now = Date()

        // Only cleanup periodically to avoid performance impact
        guard now.timeIntervalSince(lastCacheCleanup) > 60 else { return }
        lastCacheCleanup = now

        let cutoff = now.addingTimeInterval(-config.deduplicationCacheTTL)

        // Remove expired entries
        eventCache = eventCache.filter { $0.value > cutoff }

        // If still over limit, remove oldest entries
        if eventCache.count > config.maxDeduplicationCacheSize {
            let sortedEntries = eventCache.sorted { $0.value < $1.value }
            let entriesToRemove = eventCache.count - config.maxDeduplicationCacheSize
            for entry in sortedEntries.prefix(entriesToRemove) {
                eventCache.removeValue(forKey: entry.key)
            }
        }
    }

    /// Clears the event deduplication cache
    public func clearDeduplicationCache() {
        eventCache.removeAll()
    }

    /// Returns the current size of the deduplication cache
    public var deduplicationCacheSize: Int {
        eventCache.count
    }
}
