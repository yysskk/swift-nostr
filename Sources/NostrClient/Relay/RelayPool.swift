import Foundation
import NostrCore

/// Manages connections to multiple Nostr relays
public actor RelayPool {
    /// All relay connections
    private var relays: [RelayURL: RelayConnection] = [:]

    /// Subscription handlers by subscription ID
    private var subscriptionHandlers: [String: @Sendable (RelaySubscriptionMessage) async -> Void] = [:]

    /// Pool configuration
    public let config: RelayPoolConfig

    /// Creates the WebSocket transport for each relay connection. Injected so tests can
    /// supply a fake transport in place of `URLSession`.
    private let webSocketFactory: any WebSocketSessionFactory

    /// What each subscription has already delivered. Scoped per subscription rather than
    /// pool-wide so that an event matching two subscriptions is delivered to both; only the
    /// copies a single subscription receives from several relays collapse into one delivery.
    private var eventCache: EventDeduplicationCache

    /// Last time expired cache entries were swept
    private var lastCacheCleanup: Date = Date()

    /// Message listener tasks for subscriptions (keyed by subscription ID)
    private var subscriptionTasks: [String: [Task<Void, Never>]] = [:]

    /// Identifies the current listener generation for each subscription id, so a frame already in
    /// flight when the id was re-subscribed is dropped instead of reaching the new handler.
    private var subscriptionGeneration: [String: UInt64] = [:]

    /// Hands out listener generations. Pool-wide and never reset, so a number is never reused:
    /// counting per id from zero meant an unsubscribe followed by a fresh subscribe produced
    /// generation 1 both times, and a straggler from the first set matched the second.
    private var nextSubscriptionGeneration: UInt64 = 0

    /// The automatic AUTH-challenge responder applied to every relay (NIP-42)
    private var authenticationResponder: RelayConnection.AuthenticationResponder?

    public init(config: RelayPoolConfig = .default) {
        self.init(config: config, webSocketFactory: URLSessionWebSocketFactory(urlSession: .shared))
    }

    /// Creates a pool whose relay connections use the given WebSocket transport.
    ///
    /// Supply a custom ``WebSocketSessionFactory`` to run on a platform without
    /// `URLSession` WebSocket support (for example an OkHttp-backed factory on Android),
    /// or to inject a fake transport in tests so connections never touch the network.
    public init(config: RelayPoolConfig = .default, webSocketFactory: any WebSocketSessionFactory) {
        self.config = config
        self.webSocketFactory = webSocketFactory
        self.eventCache = EventDeduplicationCache(
            maxSize: config.maxDeduplicationCacheSize,
            ttl: config.deduplicationCacheTTL
        )
    }

    /// Adds a relay to the pool.
    ///
    /// Relay URLs compare by their canonical form, so re-adding the same relay under a different
    /// spelling returns the existing connection (its `config` is ignored).
    @discardableResult
    public func addRelay(_ url: RelayURL, config: RelayConnectionConfig? = nil) async -> RelayConnection {
        if let existing = relays[url] {
            return existing
        }
        let connection = RelayConnection(
            url: url,
            webSocketFactory: webSocketFactory,
            config: config ?? self.config.defaultRelayConfig
        )
        relays[url] = connection
        if let authenticationResponder {
            await connection.setAuthenticationResponder(authenticationResponder)
        }
        return connection
    }

    /// Sets or clears the responder that answers AUTH challenges automatically
    /// on every relay in the pool, both current and added later (NIP-42).
    ///
    /// See ``RelayConnection/setAuthenticationResponder(_:)`` for the
    /// per-connection semantics.
    public func setAuthenticationResponder(_ responder: RelayConnection.AuthenticationResponder?) async {
        authenticationResponder = responder
        for connection in relays.values {
            await connection.setAuthenticationResponder(responder)
        }
    }

    /// Removes a relay from the pool; removing an absent relay is a no-op.
    ///
    /// The entry is removed before the disconnect suspends, so a concurrent `addRelay` of the
    /// same relay cannot receive a connection that is about to be torn down.
    public func removeRelay(_ url: RelayURL) async {
        guard let connection = relays.removeValue(forKey: url) else { return }
        await connection.disconnect()
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

    /// Disconnects from all relays in the pool, dropping every subscription it was serving.
    ///
    /// Nothing recreates the listener tasks, and each connection clears its own tracked
    /// subscriptions on disconnect, so a later `connectAll()` restores the sockets but not the
    /// subscriptions — they have to be opened again. The handlers and dedup state are therefore
    /// dropped with the tasks rather than left behind: keeping them meant every connect/disconnect
    /// cycle grew both dictionaries while the pool reported subscriptions it could no longer serve.
    ///
    /// Callers going through ``NostrClient`` should use `relays.disconnect()`, which ends the
    /// client-facing subscription sequences before this runs.
    public func disconnectAll() async {
        // Cancel all subscription listener tasks
        for tasks in subscriptionTasks.values {
            for task in tasks {
                task.cancel()
            }
        }
        subscriptionTasks.removeAll()
        subscriptionHandlers.removeAll()
        subscriptionGeneration.removeAll()
        eventCache.removeAll()

        await withTaskGroup(of: Void.self) { group in
            for connection in relays.values {
                group.addTask {
                    await connection.disconnect()
                }
            }
        }
    }

    /// Publishes an event to connected relays.
    ///
    /// `relayURLs` is nil (the default) to broadcast to the whole pool, or the relays to
    /// target a subset (NIP-65 outbox routing); targets not in the pool are skipped. An empty
    /// set always throws — an accidentally-empty computed target list must not fan out to the
    /// whole pool.
    ///
    /// The event is sent to every targeted relay; `strategy` controls how many
    /// acknowledgments to wait for before returning (default: the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``, `.firstAck`). Returning early never
    /// cancels in-flight sends — slower relays still receive the event for redundancy,
    /// and their pending OK-waits clean themselves up on their own timeouts.
    ///
    /// - Returns: The per-relay outcome, keyed by relay URL. Relays still in flight when the
    ///   strategy was satisfied are reported as ``PublishRelayStatus/pending``.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, the last relay error if no targeted relay accepts the event, or
    ///   ``NostrError/relayError(_:)`` if a `.quorum` strategy cannot be satisfied.
    @discardableResult
    public func publish(
        _ event: Event,
        to relayURLs: Set<RelayURL>? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishResult {
        // NIP-42: the authentication event is only ever sent as an AUTH response, never
        // published as a stored event. Reject it here so a stray publish can't leak it.
        guard event.kind != .clientAuthentication else {
            throw NostrError.cannotPublishAuthenticationEvent
        }

        let connections = try targetConnections(relayURLs)

        let strategy = strategy ?? config.defaultPublishStrategy
        let requiredAcks = strategy.requiredAcks(targetCount: connections.count)

        let (results, continuation) = AsyncStream<(RelayURL, Result<Void, any Error>)>.makeStream()
        defer { continuation.finish() }

        // Deliberately unstructured: these tasks must survive an early return so the
        // EVENT frame is still delivered to every targeted relay, and so a cancelled
        // caller doesn't abort sends that are already in flight.
        for connection in connections {
            Task {
                do {
                    try await connection.publish(event)
                    continuation.yield((connection.url, .success(())))
                } catch {
                    continuation.yield((connection.url, .failure(error)))
                }
            }
        }

        var statuses: [RelayURL: PublishRelayStatus] = [:]
        for connection in connections {
            statuses[connection.url] = .pending
        }

        var successCount = 0
        var settledCount = 0
        var lastError: (any Error)?

        for await (relayURL, result) in results {
            settledCount += 1
            switch result {
            case .success:
                successCount += 1
                statuses[relayURL] = .accepted
            case .failure(let error):
                lastError = error
                statuses[relayURL] = .failed(error)
            }

            if let requiredAcks, successCount >= requiredAcks {
                return PublishResult(statuses: statuses)
            }
            if settledCount == connections.count {
                break
            }
        }

        // The stream only ends before all relays settle when the caller is cancelled;
        // surface that instead of silently returning as success.
        if settledCount < connections.count {
            try Task.checkCancellation()
        }

        if let error = Self.publishFailure(
            successCount: successCount, requiredAcks: requiredAcks, lastError: lastError)
        {
            throw error
        }
        return PublishResult(statuses: statuses)
    }

    /// Decides whether a fully settled publish failed.
    /// Succeeds if at least one relay accepted the event and any required quorum was met.
    static func publishFailure(successCount: Int, requiredAcks: Int?, lastError: (any Error)?) -> (any Error)? {
        if successCount == 0, let error = lastError {
            return error
        }
        if let requiredAcks, successCount < requiredAcks {
            return NostrError.relayError(
                "Publish quorum not met: \(successCount)/\(requiredAcks) relays acknowledged")
        }
        return nil
    }

    /// Requests NIP-45 event counts from the targeted relays.
    /// Tolerates partial failures — relays that error or time out are omitted from the result.
    ///
    /// `relayURLs` is nil (the default) to query the whole pool, or the relays to target a
    /// subset; targets not in the pool are skipped. An empty set always throws — an
    /// accidentally-empty computed target list must not fan out to the whole pool.
    ///
    /// - Returns: the per-relay count for every relay that answered, keyed by relay URL.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or the last relay error when no targeted relay answered.
    public func countEvents(
        matching filters: [Filter],
        from relayURLs: Set<RelayURL>? = nil,
        timeout: TimeInterval = 10
    ) async throws -> [RelayURL: EventCount] {
        let connections = try targetConnections(relayURLs)

        return try await withThrowingTaskGroup(of: (RelayURL, Result<EventCount, any Error>).self) { group in
            for connection in connections {
                group.addTask {
                    do {
                        let count = try await connection.countEvents(matching: filters, timeout: timeout)
                        return (connection.url, .success(count))
                    } catch {
                        return (connection.url, .failure(error))
                    }
                }
            }

            var results: [RelayURL: EventCount] = [:]
            var lastError: (any Error)?
            for try await (url, result) in group {
                switch result {
                case .success(let count):
                    results[url] = count
                case .failure(let error):
                    lastError = error
                }
            }

            // No relay answered: surface a failure rather than an empty dictionary.
            if results.isEmpty {
                throw lastError ?? NostrError.notConnected
            }
            return results
        }
    }

    /// Subscribes to events on the targeted relays.
    /// Tolerates partial failures - succeeds if at least one relay accepts the subscription.
    /// Events are deduplicated across the relays of this subscription: each event is
    /// delivered once here however many relays send it, while other subscriptions matching
    /// the same event still receive their own copy.
    ///
    /// `relayURLs` is nil (the default) to subscribe on the whole pool, or the relays to
    /// target a subset; targets not in the pool are skipped. An empty set always throws — an
    /// accidentally-empty computed target list must not fan out to the whole pool.
    /// - Returns: The number of relays that successfully subscribed
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or ``NostrError/relayError(_:)`` when every relay fails to subscribe.
    @discardableResult
    public func subscribe(
        subscriptionID: String,
        filters: [Filter],
        to relayURLs: Set<RelayURL>? = nil,
        handler: @escaping @Sendable (RelayMessage) -> Void
    ) async throws -> Int {
        let successfulRelayURLs = try await subscribeWithRelayContext(
            subscriptionID: subscriptionID,
            filters: filters,
            to: relayURLs
        ) { relayMessage in
            handler(relayMessage.message)
        }

        return successfulRelayURLs.count
    }

    /// Core of the subscribe paths, taking the target relays (nil = whole pool) and a
    /// relay-aware handler.
    @discardableResult
    func subscribeWithRelayContext(
        subscriptionID: String,
        filters: [Filter],
        to relayURLs: Set<RelayURL>?,
        handler: @escaping @Sendable (RelaySubscriptionMessage) async -> Void
    ) async throws -> Set<RelayURL> {
        let connections = try targetConnections(relayURLs)

        // Re-subscribing under an id already in use replaces the previous generation. Its tasks are
        // cancelled, but cancellation alone does not stop a frame already in flight: the listener
        // resolves the handler at delivery time, so a straggler would be handed to the *new*
        // handler and every control message delivered twice. The generation is what a straggler
        // fails, so only the current one delivers.
        cancelListenerTasks(for: subscriptionID)
        nextSubscriptionGeneration &+= 1
        let generation = nextSubscriptionGeneration
        subscriptionGeneration[subscriptionID] = generation
        subscriptionHandlers[subscriptionID] = handler
        // The dedup cache is scoped to the id, not the generation, and a fresh REQ makes the relay
        // resend its stored events. Left in place, everything the previous generation already saw
        // would be discarded as a duplicate before the new handler — which never received it — had
        // a chance to.
        eventCache.removeSubscription(subscriptionID)

        // Start listening for messages BEFORE sending the subscription request, so nothing that
        // arrives immediately after it is missed. `messages()` is awaited here rather than inside
        // the task: that registers the stream on the connection before this call proceeds, whereas
        // spawning a task and yielding only made it *likely* the registration had happened.
        var tasks: [Task<Void, Never>] = []
        for connection in connections {
            let messages = await connection.messages()
            let task = Task {
                for await message in messages {
                    guard !Task.isCancelled else { break }
                    let relayURL = connection.url
                    switch message {
                    case .event(let incomingID, let event) where incomingID == subscriptionID:
                        // Deduplicate the copies of one event arriving from several relays,
                        // scoped to this subscription so a different subscription matching the
                        // same event still receives it.
                        let isNewToSubscription = self.recordEvent(
                            eventID: event.id,
                            subscriptionID: subscriptionID
                        )
                        if isNewToSubscription,
                            let currentHandler = self.handler(
                                for: subscriptionID, generation: generation)
                        {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    case .endOfStoredEvents(let incomingID) where incomingID == subscriptionID:
                        if let currentHandler = self.handler(for: subscriptionID, generation: generation) {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    case .closed(let incomingID, _) where incomingID == subscriptionID:
                        if let currentHandler = self.handler(for: subscriptionID, generation: generation) {
                            await currentHandler(
                                RelaySubscriptionMessage(
                                    relayURL: relayURL,
                                    message: message
                                )
                            )
                        }
                    case .notice, .auth:
                        if let currentHandler = self.handler(for: subscriptionID, generation: generation) {
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

        // Registering the stream suspends, so another subscribe on this id may have run to
        // completion in between. Publishing these tasks then would strand its listeners with no
        // way to cancel them; this generation is finished instead.
        guard subscriptionGeneration[subscriptionID] == generation else {
            for task in tasks { task.cancel() }
            throw NostrError.relayError("The subscription was superseded before it was established")
        }
        subscriptionTasks[subscriptionID] = tasks

        // Now send subscription requests to all relays, tolerating failures
        var successfulRelayURLs: Set<RelayURL> = []

        await withTaskGroup(of: RelayURL?.self) { group in
            for connection in connections {
                group.addTask {
                    do {
                        try await connection.subscribe(subscriptionID: subscriptionID, filters: filters)
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

        // A failed subscribe must not leak handler/listener/cache state when the pool is
        // used directly.
        // Only tear down what this generation registered: a newer subscribe on the same id may
        // have replaced it while the REQs were in flight, and its state is not ours to remove.
        if successfulRelayURLs.isEmpty {
            if subscriptionGeneration[subscriptionID] == generation {
                subscriptionHandlers.removeValue(forKey: subscriptionID)
                cancelListenerTasks(for: subscriptionID)
                subscriptionGeneration.removeValue(forKey: subscriptionID)
                eventCache.removeSubscription(subscriptionID)
            }
            throw NostrError.relayError("Failed to subscribe on any relay")
        }

        return successfulRelayURLs
    }

    /// The handler for `subscriptionID`, or nil when `generation` is no longer the current listener
    /// generation — the id has since been re-subscribed, and this frame belongs to the old one.
    private func handler(
        for subscriptionID: String,
        generation: UInt64
    ) -> (@Sendable (RelaySubscriptionMessage) async -> Void)? {
        guard subscriptionGeneration[subscriptionID] == generation else { return nil }
        return subscriptionHandlers[subscriptionID]
    }

    /// Cancels and forgets the listener tasks for `subscriptionID`, if any.
    private func cancelListenerTasks(for subscriptionID: String) {
        guard let tasks = subscriptionTasks.removeValue(forKey: subscriptionID) else { return }
        for task in tasks {
            task.cancel()
        }
    }

    /// Unsubscribes from a subscription on all relays, discarding its deduplication cache.
    /// Tolerates partial failures - best effort unsubscription.
    public func unsubscribe(subscriptionID: String) async {
        subscriptionHandlers.removeValue(forKey: subscriptionID)
        cancelListenerTasks(for: subscriptionID)
        subscriptionGeneration.removeValue(forKey: subscriptionID)

        eventCache.removeSubscription(subscriptionID)

        await withTaskGroup(of: Void.self) { group in
            for connection in relays.values {
                group.addTask {
                    try? await connection.unsubscribe(subscriptionID: subscriptionID)
                }
            }
        }
    }

    /// Returns all relay connections
    public var connections: [RelayConnection] {
        Array(relays.values)
    }

    /// Returns the relay connection for a relay URL, or nil when it is not in the pool.
    public func relay(for url: RelayURL) -> RelayConnection? {
        relays[url]
    }

    /// Resolves the connections to target for a routed operation.
    /// `nil` targets all relays in the pool (the default broadcast behavior);
    /// a non-nil set targets only those relays currently present in the pool,
    /// and partial matches proceed with the present subset.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty, or
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the requested URLs are in
    ///   the pool (including an empty set).
    func targetConnections(_ relayURLs: Set<RelayURL>?) throws -> [RelayConnection] {
        guard let relayURLs else {
            guard !relays.isEmpty else { throw NostrError.noRelaysInPool }
            return Array(relays.values)
        }
        let connections = relayURLs.compactMap { relays[$0] }
        guard !connections.isEmpty else {
            throw NostrError.noMatchingRelays(relayURLs.sorted { $0.description < $1.description })
        }
        return connections
    }

    /// The number of registered subscription handlers (test hook).
    var subscriptionHandlerCount: Int { subscriptionHandlers.count }

    /// The listener generation currently serving `subscriptionID` (for tests).
    func subscriptionGeneration(for subscriptionID: String) -> UInt64? {
        subscriptionGeneration[subscriptionID]
    }

    /// The number of listener tasks registered for `subscriptionID` (for tests).
    func listenerTaskCount(for subscriptionID: String) -> Int {
        subscriptionTasks[subscriptionID]?.count ?? 0
    }

    /// The number of subscriptions with live listener tasks (test hook).
    var subscriptionTaskCount: Int { subscriptionTasks.count }

    /// Returns the number of relays in the pool
    public var relayCount: Int {
        relays.count
    }

    /// Returns the number of connected relays
    public func connectedRelayCount() async -> Int {
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
    /// Adds multiple relays, each with the pool's default connection configuration.
    public func addRelays(_ urls: some Sequence<RelayURL>) async {
        for url in urls {
            await addRelay(url)
        }
    }
}

// MARK: - Event Deduplication
extension RelayPool {
    /// Records that `subscriptionID` has seen `eventID`, returning whether it is new to that
    /// subscription — that is, whether this copy should be delivered to its handler.
    private func recordEvent(eventID: EventID, subscriptionID: String) -> Bool {
        expireCachedEventsIfNeeded()
        return eventCache.record(eventID: eventID, subscriptionID: subscriptionID)
    }

    /// Sweeps expired entries, at most once a minute so the sweep never dominates event
    /// handling. Only the TTL needs sweeping: ``EventDeduplicationCache`` holds the pool-wide
    /// size limit as events are recorded.
    private func expireCachedEventsIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastCacheCleanup) > 60 else { return }
        lastCacheCleanup = now
        expireCachedEvents(now: now)
    }

    /// Removes cache entries past ``RelayPoolConfig/deduplicationCacheTTL`` (test hook: called
    /// directly with the `now` the sweep should see, rather than waiting out the interval).
    func expireCachedEvents(now: Date = Date()) {
        eventCache.removeExpired(now: now)
    }

    /// Clears every subscription's event deduplication cache
    public func clearDeduplicationCache() {
        eventCache.removeAll()
    }

    /// Returns the current number of cached event IDs, summed over every subscription
    public var deduplicationCacheSize: Int {
        eventCache.count
    }

    /// The number of cached event IDs for a single subscription (test hook).
    func deduplicationCacheSize(forSubscription subscriptionID: String) -> Int {
        eventCache.count(forSubscription: subscriptionID)
    }
}
