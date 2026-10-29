import Foundation
import NostrCore

/// Manages connections to multiple Nostr relays
public actor RelayPool {
    /// All relay connections
    private var relays: [RelayURL: RelayConnection] = [:]

    /// The subscriptions this pool is serving, by id.
    private var subscriptions: [SubscriptionID: ActiveSubscription] = [:]

    /// Pool configuration
    public let config: RelayPoolConfig

    /// Creates the WebSocket transport for each relay connection. Injected so tests can
    /// supply a fake transport in place of `URLSession`.
    private let webSocketFactory: any WebSocketSessionFactory

    /// What each subscription has already delivered. Scoped per subscription rather than
    /// pool-wide so that an event matching two subscriptions is delivered to both; only the
    /// copies a single subscription receives from several relays collapse into one delivery.
    /// `nil` when ``RelayPoolConfig/deduplication`` is, so every copy is delivered.
    private var eventCache: EventDeduplicationCache?

    /// Last time expired cache entries were swept
    private var lastCacheCleanup: ContinuousClock.Instant = .now

    /// The automatic AUTH-challenge responder applied to every relay (NIP-42)
    private var authenticationResponder: RelayConnection.AuthenticationResponder?

    /// Creates a pool.
    ///
    /// By default every relay connection's sockets come from a ``URLSessionWebSocketFactory`` over
    /// `URLSession.shared`. Supply a custom ``WebSocketSessionFactory`` to run on a platform without
    /// working `URLSession` WebSocket support (for example an OkHttp-backed factory on Android),
    /// or to inject a fake transport in tests so connections never touch the network.
    /// - Parameters:
    ///   - config: Pool behavior, including each relay connection's default configuration.
    ///   - webSocketFactory: Creates the transport for each relay connection (defaults to a
    ///     ``URLSessionWebSocketFactory`` over `URLSession.shared`).
    public init(
        config: RelayPoolConfig = .default,
        webSocketFactory: any WebSocketSessionFactory = URLSessionWebSocketFactory()
    ) {
        self.config = config
        self.webSocketFactory = webSocketFactory
        self.eventCache = config.deduplication.map {
            EventDeduplicationCache(maximumSize: $0.maximumCount, ttl: $0.timeToLive)
        }
    }

    /// Adds a relay to the pool.
    ///
    /// Relay URLs compare by their canonical form, so re-adding the same relay under a different
    /// spelling returns the existing connection (its `config` is ignored).
    @discardableResult
    public func add(_ url: RelayURL, config: RelayConnectionConfig? = nil) async -> RelayConnection {
        if let existing = relays[url] {
            return existing
        }
        let connection = RelayConnection(
            url: url,
            config: config ?? self.config.defaultRelayConfig,
            webSocketFactory: webSocketFactory
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
    /// The entry is removed before the disconnect suspends, so a concurrent `add(_:config:)` of the
    /// same relay cannot receive a connection that is about to be torn down.
    public func remove(_ url: RelayURL) async {
        guard let connection = relays.removeValue(forKey: url) else { return }
        await connection.disconnect()
    }

    /// Connects to all relays in the pool.
    /// Tolerates partial failures - succeeds if at least one relay connects.
    /// - Returns: The number of successfully connected relays
    /// - Throws: ``RelayPool/Error/allConnectionsFailed`` when the pool is not empty and every
    ///   relay fails to connect.
    @discardableResult
    public func connect() async throws(Error) -> Int {
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
            throw .allConnectionsFailed
        }

        return successCount
    }

    /// Disconnects from all relays in the pool, ending every subscription it was serving.
    ///
    /// Each subscription is closed first — CLOSE goes out while the connections are still up and
    /// its sequence ends — because nothing would deliver to it afterwards: each connection clears
    /// its own tracked subscriptions on disconnect, so a later ``connect()`` restores the sockets
    /// but not the subscriptions. They have to be opened again.
    public func disconnect() async {
        await unsubscribeAll()
        eventCache?.removeAll()

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
    /// - Throws: ``RelayPool/Error/cannotPublishAuthenticationEvent`` for a kind-22242 event,
    ///   ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, the last relay's error (a ``RelayRejection`` or a ``RelayConnection/Error``) if no
    ///   targeted relay accepts the event, or ``RelayPool/Error/quorumNotMet(acknowledged:required:)``
    ///   if a `.quorum` strategy cannot be satisfied.
    @discardableResult
    public func publish(
        _ event: Event,
        to relayURLs: Set<RelayURL>? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishResult {
        // NIP-42: the authentication event is only ever sent as an AUTH response, never
        // published as a stored event. Reject it here so a stray publish can't leak it.
        guard event.kind != .clientAuthentication else {
            throw Error.cannotPublishAuthenticationEvent
        }

        let connections = try targetConnections(relayURLs)

        let strategy = strategy ?? config.defaultPublishStrategy
        let requiredAcks = strategy.requiredAcks(targetCount: connections.count)

        let (results, continuation) = AsyncStream<(RelayURL, Result<Void, any Swift.Error>)>.makeStream()
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
        var lastError: (any Swift.Error)?

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
    static func publishFailure(
        successCount: Int, requiredAcks: Int?, lastError: (any Swift.Error)?
    ) -> (any Swift.Error)? {
        if successCount == 0, let error = lastError {
            return error
        }
        if let requiredAcks, successCount < requiredAcks {
            return Error.quorumNotMet(acknowledged: successCount, required: requiredAcks)
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
    /// - Parameters:
    ///   - filters: The filters whose matching events to count.
    ///   - relayURLs: The relays to query, or nil for the whole pool.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: the per-relay count for every relay that answered, keyed by relay URL.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or the last relay's error (a ``RelayRejection`` or a ``RelayConnection/Error``) when
    ///   no targeted relay answered.
    public func countEvents(
        matching filters: [Filter],
        from relayURLs: Set<RelayURL>? = nil,
        timeout: Duration? = nil
    ) async throws -> [RelayURL: EventCount] {
        let connections = try targetConnections(relayURLs)
        // Passed to every connection explicitly so the pool's setting governs pool calls, not
        // each relay's own `RelayConnectionConfig/queryTimeout`.
        let timeout = timeout ?? config.queryTimeout

        return try await withThrowingTaskGroup(of: (RelayURL, Result<EventCount, any Swift.Error>).self) { group in
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
            var lastError: (any Swift.Error)?
            for try await (url, result) in group {
                switch result {
                case .success(let count):
                    results[url] = count
                case .failure(let error):
                    lastError = error
                }
            }

            // No relay answered: surface a failure rather than an empty dictionary. At least one
            // relay was targeted, so a failure was recorded whenever nothing answered.
            if results.isEmpty, let lastError {
                throw lastError
            }
            return results
        }
    }

    /// Opens a subscription under a fresh ``SubscriptionID`` on the whole pool (nil) or the given
    /// relays, as an async sequence of relay-aware events.
    ///
    /// Tolerates partial failures — succeeds if at least one relay accepts the REQ. Events are
    /// deduplicated across the relays of this subscription: each event is delivered once however
    /// many relays send it, while other subscriptions matching the same event still receive their
    /// own copy. With ``RelayPoolConfig/deduplication`` set to `nil`, every relay's copy is
    /// delivered.
    ///
    /// Targets not in the pool are skipped; an empty set always throws — an accidentally-empty
    /// computed target list must not fan out to the whole pool. Ending iteration, cancelling the
    /// consuming task, discarding the sequence, or ``unsubscribe(id:)`` sends CLOSE.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on, or nil for the whole pool.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays.
    /// - Returns: The subscription; its ``SubscriptionSequence/expectedRelays`` are the relays that
    ///   accepted the REQ.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the
    ///   pool, or ``RelayPool/Error/subscriptionFailed`` when every relay fails to subscribe.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<RelayURL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws(Error) -> SubscriptionSequence {
        let connections = try targetConnections(relayURLs)
        let id = SubscriptionID.random()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubscriptionEvent.self,
            bufferingPolicy: bufferingPolicy
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(id: id) }
        }
        // Registered before anything suspends, so an `unsubscribeAll()` or `disconnect()` that
        // runs while this subscription is being set up ends it too.
        subscriptions[id] = ActiveSubscription(continuation: continuation)

        // Start listening for messages BEFORE sending the subscription request, so nothing that
        // arrives immediately after it is missed. `messages()` is awaited here rather than inside
        // the task: that registers the stream on the connection before this call proceeds, whereas
        // spawning a task and yielding only made it *likely* the registration had happened.
        var listeners: [Task<Void, Never>] = []
        for connection in connections {
            let messages = await connection.messages()
            let relayURL = connection.url
            listeners.append(
                Task {
                    for await message in messages {
                        guard !Task.isCancelled else { break }
                        self.deliver(message, from: relayURL, to: id)
                    }
                })
        }
        // Registering the streams suspends, so the subscription may have been closed in between:
        // its sequence has already ended, and these listeners have no one left to cancel them.
        guard subscriptions[id] != nil else {
            for listener in listeners { listener.cancel() }
            return SubscriptionSequence(id: id, expectedRelays: [], stream: stream, onClose: {})
        }
        subscriptions[id]?.listeners = listeners

        // Now send subscription requests to all relays, tolerating failures
        var acceptingRelayURLs: Set<RelayURL> = []

        await withTaskGroup(of: RelayURL?.self) { group in
            for connection in connections {
                group.addTask {
                    do {
                        try await connection.subscribe(id: id, filters: filters)
                        return connection.url
                    } catch {
                        return nil
                    }
                }
            }

            for await relayURL in group {
                if let relayURL {
                    acceptingRelayURLs.insert(relayURL)
                }
            }
        }

        // No relay holds the subscription, so there is nothing to CLOSE — only this pool's state.
        if acceptingRelayURLs.isEmpty {
            removeSubscription(id)
            throw .subscriptionFailed
        }
        // Closed while the REQs were in flight: its CLOSE may have reached a connection before the
        // REQ did, leaving the subscription open on that relay, so close it again now.
        if subscriptions[id] == nil {
            await sendClose(id)
        }

        return SubscriptionSequence(
            id: id,
            expectedRelays: acceptingRelayURLs,
            stream: stream,
            onClose: { [weak self] in
                await self?.unsubscribe(id: id)
            }
        )
    }

    /// Hands a message from `relayURL` to subscription `id` while it is open: its own EVENT, EOSE,
    /// and CLOSED, and every NOTICE and AUTH challenge, which concern all of the relay's
    /// subscriptions.
    private func deliver(_ message: RelayMessage, from relayURL: RelayURL, to id: SubscriptionID) {
        guard let continuation = subscriptions[id]?.continuation else { return }
        switch message {
        case .event(let subscriptionID, let event) where subscriptionID == id:
            // Deduplicate the copies of one event arriving from several relays, scoped to this
            // subscription so a different subscription matching the same event still receives it.
            guard recordEvent(eventID: event.id, subscriptionID: id) else { return }
            continuation.yield(.event(relayURL: relayURL, event: event))
        case .endOfStoredEvents(let subscriptionID) where subscriptionID == id:
            continuation.yield(.eose(relayURL: relayURL))
        case .closed(let subscriptionID, let message) where subscriptionID == id:
            continuation.yield(.closed(relayURL: relayURL, message: message))
        case .notice(let message):
            continuation.yield(.notice(relayURL: relayURL, message: message))
        case .auth(let challenge):
            continuation.yield(.auth(relayURL: relayURL, challenge: challenge))
        default:
            break
        }
    }

    /// Closes one subscription: ends its sequence, discards its deduplication cache, and sends
    /// CLOSE to the relays. A no-op for an id this pool is not serving, so the call made again when
    /// the sequence ends cannot send a second CLOSE.
    ///
    /// A CLOSE goes only to the connected relays holding the subscription; a disconnected,
    /// failed, or reconnecting relay is not reconnected to receive one (see
    /// ``RelayConnection/unsubscribe(id:)``). Best effort: a CLOSE that fails to send is
    /// not reported.
    public func unsubscribe(id: SubscriptionID) async {
        guard removeSubscription(id) else { return }
        await sendClose(id)
    }

    /// Closes every subscription this pool is serving.
    public func unsubscribeAll() async {
        for id in subscriptions.keys {
            await unsubscribe(id: id)
        }
    }

    /// Sends CLOSE for `id` to every connected relay holding it.
    private func sendClose(_ id: SubscriptionID) async {
        await withTaskGroup(of: Void.self) { group in
            for connection in relays.values {
                group.addTask {
                    await connection.unsubscribe(id: id)
                }
            }
        }
    }

    /// Forgets subscription `id` — cancelling its listeners, ending its sequence, and discarding
    /// its deduplication cache — and returns whether it was open.
    @discardableResult
    private func removeSubscription(_ id: SubscriptionID) -> Bool {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return false }
        for listener in subscription.listeners {
            listener.cancel()
        }
        subscription.continuation.finish()
        eventCache?.removeSubscription(id)
        return true
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
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty, or
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of the requested URLs are in
    ///   the pool (including an empty set).
    func targetConnections(_ relayURLs: Set<RelayURL>?) throws(Error) -> [RelayConnection] {
        guard let relayURLs else {
            guard !relays.isEmpty else { throw .emptyPool }
            return Array(relays.values)
        }
        let connections = relayURLs.compactMap { relays[$0] }
        guard !connections.isEmpty else {
            throw .noMatchingRelays(relayURLs.sorted { $0.description < $1.description })
        }
        return connections
    }

    /// The number of open subscriptions (test hook).
    var subscriptionCount: Int { subscriptions.count }

    /// The number of listener tasks registered for subscription `id` (test hook).
    func listenerTaskCount(for id: SubscriptionID) -> Int {
        subscriptions[id]?.listeners.count ?? 0
    }

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
    public func add(_ urls: some Sequence<RelayURL>) async {
        for url in urls {
            await add(url)
        }
    }
}

// MARK: - Event Deduplication
extension RelayPool {
    /// Records that `subscriptionID` has seen `eventID`, returning whether it is new to that
    /// subscription — that is, whether this copy should be delivered to its sequence.
    private func recordEvent(eventID: EventID, subscriptionID: SubscriptionID) -> Bool {
        guard eventCache != nil else { return true }
        expireCachedEventsIfNeeded()
        return eventCache?.record(eventID: eventID, subscriptionID: subscriptionID) ?? true
    }

    /// Sweeps expired entries, at most once a minute so the sweep never dominates event
    /// handling. Only the TTL needs sweeping: ``EventDeduplicationCache`` holds the pool-wide
    /// size limit as events are recorded.
    private func expireCachedEventsIfNeeded() {
        let now = ContinuousClock.now
        guard now - lastCacheCleanup > .seconds(60) else { return }
        lastCacheCleanup = now
        expireCachedEvents(now: now)
    }

    /// Removes cache entries past ``RelayPoolConfig/Deduplication/timeToLive`` (test hook: called
    /// directly with the `now` the sweep should see, rather than waiting out the interval).
    func expireCachedEvents(now: ContinuousClock.Instant = .now) {
        eventCache?.removeExpired(now: now)
    }

    /// Clears every subscription's event deduplication cache
    public func clearDeduplicationCache() {
        eventCache?.removeAll()
    }

    /// Returns the current number of cached event IDs, summed over every subscription
    public var deduplicationCacheSize: Int {
        eventCache?.count ?? 0
    }

    /// The number of cached event IDs for a single subscription (test hook).
    func deduplicationCacheSize(forSubscription subscriptionID: SubscriptionID) -> Int {
        eventCache?.count(forSubscription: subscriptionID) ?? 0
    }
}

// MARK: - Error
extension RelayPool {
    /// Why a pool-level operation failed.
    ///
    /// Failures of an individual relay surface as that relay's own error — a ``RelayRejection``
    /// or a ``RelayConnection/Error`` — when no targeted relay succeeded.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// A relay-targeted operation ran against an empty pool.
        case emptyPool
        /// None of the targeted relay URLs are in the pool, or the target set was empty
        /// (payload: the targets, sorted by their canonical string).
        case noMatchingRelays([RelayURL])
        /// A NIP-42 authentication event (kind 22242) was passed to a publish; it is only ever sent
        /// as an AUTH response.
        case cannotPublishAuthenticationEvent
        /// A ``PublishStrategy/quorum(_:)`` publish settled with fewer acknowledgments than it required
        /// (payload: the number of relays that accepted the event, and the quorum).
        case quorumNotMet(acknowledged: Int, required: Int)
        /// Every targeted relay failed to accept the subscription.
        case subscriptionFailed
        /// Every relay in the pool failed to connect.
        case allConnectionsFailed

        public var errorDescription: String? {
            switch self {
            case .emptyPool:
                return "The relay pool is empty — add relays with add(_:) or connect(to:) first"
            case .noMatchingRelays(let requested):
                if requested.isEmpty {
                    return "The target relay list is empty"
                }
                return
                    "None of the targeted relays are in the pool: \(requested.map(\.description).joined(separator: ", "))"
            case .cannotPublishAuthenticationEvent:
                return
                    "NIP-42 authentication events (kind 22242) must not be published; they are only sent as AUTH responses"
            case .quorumNotMet(let acknowledged, let required):
                return "Publish quorum not met: \(acknowledged)/\(required) relays acknowledged"
            case .subscriptionFailed:
                return "Failed to subscribe on any relay"
            case .allConnectionsFailed:
                return "All relays failed to connect"
            }
        }
    }
}

/// A subscription a ``RelayPool`` is serving.
private struct ActiveSubscription {
    /// Feeds the subscription's ``SubscriptionSequence``.
    let continuation: AsyncStream<SubscriptionEvent>.Continuation
    /// One task per targeted relay, reading its messages.
    var listeners: [Task<Void, Never>] = []
}
