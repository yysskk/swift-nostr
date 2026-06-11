import Foundation

/// Main entry point for the Nostr client library
public actor NostrClient {
    /// The relay pool managing all connections
    public let relayPool: RelayPool

    /// The event signer (optional, required for publishing)
    private var signer: EventSigner?

    /// Subscription counter for generating unique IDs
    private var subscriptionCounter: Int = 0

    /// Active subscriptions
    private var subscriptions: [String: SubscriptionState] = [:]

    /// Per-pubkey NIP-65 relay list cache and outbox/gossip resolver
    private let relayListStore: RelayListStore

    public init(
        relayPoolConfig: RelayPoolConfig = .default,
        gossipPolicy: GossipRelayPolicy = .addAndConnect
    ) {
        let pool = RelayPool(config: relayPoolConfig)
        self.relayPool = pool
        self.relayListStore = RelayListStore(pool: pool, policy: gossipPolicy)
    }

    /// Sets the signer for publishing events
    public func setSigner(_ signer: EventSigner) {
        self.signer = signer
    }

    /// Sets the signer from a private key hex string
    public func setPrivateKey(_ privateKeyHex: String) throws {
        self.signer = try EventSigner(privateKeyHex: privateKeyHex)
    }

    /// Sets the signer from an nsec
    public func setNsec(_ nsec: String) throws {
        self.signer = try EventSigner(nsec: nsec)
    }

    /// Returns the public key if a signer is set
    public var publicKey: String? {
        signer?.publicKey
    }

    /// Returns the npub if a signer is set
    public var npub: String? {
        signer?.npub
    }

    // MARK: - Relay Management

    /// Adds a relay
    @discardableResult
    public func addRelay(_ urlString: String) async throws -> RelayConnection {
        try await relayPool.addRelay(urlString: urlString)
    }

    /// Adds multiple relays
    public func addRelays(_ urlStrings: [String]) async throws {
        for urlString in urlStrings {
            _ = try await relayPool.addRelay(urlString: urlString)
        }
    }

    /// Connects to all relays
    public func connect() async throws {
        try await relayPool.connectAll()
    }

    /// Disconnects from all relays
    public func disconnect() async {
        await relayPool.disconnectAll()
    }

    // MARK: - Publishing

    /// Publishes a text note
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishTextNote(
        content: String,
        tags: [Tag] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let event = try signer.signTextNote(content: content, tags: tags)
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a reply to an event
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReply(
        to event: Event,
        content: String,
        relayUrl: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        var tags: [Tag] = []

        // Add root and reply markers (NIP-10)
        if let rootTag = event.tags(named: "e").first(where: { $0.values.contains("root") }) {
            tags.append(rootTag)
            tags.append(.event(event.id, relayURL: relayUrl, marker: .reply))
        } else {
            // This is a reply to a root event
            tags.append(.event(event.id, relayURL: relayUrl, marker: .root))
        }

        // Add p tag for the author we're replying to
        tags.append(.pubkey(event.pubkey))

        let unsigned = UnsignedEvent(
            pubkey: signer.publicKey,
            kind: .textNote,
            tags: tags,
            content: content
        )

        let signedEvent = try signer.sign(unsigned)
        let result = try await relayPool.publish(signedEvent, strategy: strategy)
        return PublishedEvent(event: signedEvent, result: result)
    }

    /// Publishes user metadata
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishMetadata(
        _ metadata: UserMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let event = try signer.signMetadata(metadata)
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a reaction to an event
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReaction(
        to event: Event,
        content: String = "+",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let reaction = try signer.signReaction(to: event, content: content)
        let result = try await relayPool.publish(reaction, strategy: strategy)
        return PublishedEvent(event: reaction, result: result)
    }

    /// Publishes a repost
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRepost(
        of event: Event,
        relayUrl: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let repost = try signer.signRepost(of: event, relayUrl: relayUrl)
        let result = try await relayPool.publish(repost, strategy: strategy)
        return PublishedEvent(event: repost, result: result)
    }

    /// Publishes a deletion request
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDeletion(
        eventIds: [String],
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let deletion = try signer.signDeletion(eventIds: eventIds, reason: reason)
        let result = try await relayPool.publish(deletion, strategy: strategy)
        return PublishedEvent(event: deletion, result: result)
    }

    /// Publishes a raw signed event.
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publish(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        try await relayPool.publish(event, strategy: strategy)
    }

    // MARK: - Private Direct Messages (NIP-17)

    /// Sends a private direct message to a recipient using NIP-17.
    ///
    /// One unsigned kind-14 rumor is wrapped twice: once for the recipient and once
    /// for the sender (the NIP-17 self-copy that provides sent history and
    /// multi-device sync). Both gift wraps are published in parallel; the message
    /// succeeds when the recipient copy is accepted, and a failed self-copy publish
    /// is non-fatal.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPubkey: The recipient's public key (hex)
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional event ID to reply to
    ///   - strategy: How many relay acknowledgments to wait for on the recipient
    ///     gift wrap before returning (default: the pool config's
    ///     ``RelayPoolConfig/defaultPublishStrategy``). The best-effort self-copy
    ///     always uses the pool default so it never blocks the send.
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish
    ///   outcomes. The rumor's `id` is the key for matching the message when it
    ///   echoes back from a relay.
    @discardableResult
    public func sendDirectMessage(
        _ content: String,
        to recipientPubkey: String,
        subject: String? = nil,
        replyTo: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        guard let keyPair = try? getKeyPair() else {
            throw NostrError.signingFailed
        }

        let builder = DirectMessageBuilder(keyPair: keyPair)
        let result = try builder.createMessageWithSelfCopy(
            content: content,
            to: recipientPubkey,
            subject: subject,
            replyTo: replyTo
        )

        async let selfCopyDelivery = publishBestEffort(result.selfGiftWrap)
        let recipientResult = try await relayPool.publish(result.recipientGiftWrap, strategy: strategy)
        let selfCopyResult = await selfCopyDelivery

        return SendDirectMessageResult(
            rumor: result.rumor,
            recipientGiftWrap: result.recipientGiftWrap,
            selfGiftWrap: result.selfGiftWrap,
            recipientPublishResult: recipientResult,
            selfCopyPublishResult: selfCopyResult
        )
    }

    /// Publishes an event, swallowing failures (used for non-fatal NIP-17 self-copies).
    /// Always uses the pool's default strategy so a caller-supplied strategy
    /// never makes the best-effort publish block the primary send.
    /// - Returns: The per-relay outcome, or nil if the publish failed outright.
    private func publishBestEffort(_ event: Event) async -> PublishResult? {
        try? await relayPool.publish(event)
    }

    /// Parses a received gift-wrapped direct message
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed DirectMessage
    public func parseDirectMessage(_ giftWrap: Event) throws -> DirectMessage {
        guard let keyPair = try? getKeyPair() else {
            throw NostrError.signingFailed
        }

        let parser = DirectMessageParser(keyPair: keyPair)
        return try parser.parse(giftWrap)
    }

    /// Subscribes to private direct messages (gift-wrapped events) for the current user.
    /// - Parameter limit: Maximum number of messages to fetch
    /// - Returns: A subscription sequence of gift-wrapped events; parse each with
    ///   ``parseDirectMessage(_:)``.
    public func subscribeToDirectMessages(
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [directMessagesFilter(limit: limit)])
    }

    /// Subscribes to private direct messages for the current user
    /// - Parameters:
    ///   - limit: Maximum number of messages to fetch
    ///   - handler: Handler called for each gift-wrapped event
    /// - Returns: The subscription ID
    @available(*, deprecated, message: "Use subscribeToDirectMessages(limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToDirectMessages(
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [directMessagesFilter(limit: limit)], to: nil, handler: Self.eventOnly(handler)
        ).id
    }

    /// Subscribes to private direct messages for the current user.
    /// - Parameters:
    ///   - limit: Maximum number of messages to fetch
    ///   - eventHandler: Handler called for each subscription event
    /// - Returns: The subscription ID
    @available(*, deprecated, message: "Use subscribeToDirectMessages(limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToDirectMessages(
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [directMessagesFilter(limit: limit)], to: nil, handler: eventHandler
        ).id
    }

    /// Builds the gift-wrap filter for the current user's direct messages.
    private func directMessagesFilter(limit: Int) throws -> Filter {
        guard let publicKey = publicKey else {
            throw NostrError.signingFailed
        }
        return Filter(
            kinds: [.giftWrap],
            pubkeyReferences: [publicKey],
            limit: limit
        )
    }

    /// Helper to get the keypair from the signer
    private func getKeyPair() throws -> KeyPair {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        return signer.keyPair
    }

    // MARK: - Subscriptions

    /// Opens a subscription and returns it as an async sequence of relay-aware events.
    ///
    /// Pass `relayURLs` to scope the subscription to a subset of relays (NIP-65 outbox routing);
    /// the default `nil` subscribes on all relays in the pool.
    ///
    /// Iteration termination (breaking out of the loop, task cancellation, or
    /// discarding the sequence) automatically sends CLOSE to the relays.
    /// - Parameter bufferingPolicy: How items are buffered while the consumer is
    ///   slower than the relays (default: `.unbounded`). Use
    ///   `.bufferingNewest(n)` for firehose subscriptions where memory matters.
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SubscriptionEvent.self,
            bufferingPolicy: bufferingPolicy
        )

        let opened: (id: String, expectedRelays: Set<URL>)
        do {
            opened = try await openSubscription(filters: filters, to: relayURLs) { subscriptionEvent in
                continuation.yield(subscriptionEvent)
            }
        } catch {
            continuation.finish()
            throw error
        }

        // The actor was free during the await above: if the subscription was
        // already torn down (e.g. unsubscribeAll), end the stream immediately.
        if subscriptions[opened.id] != nil {
            subscriptions[opened.id]?.continuation = continuation
        } else {
            continuation.finish()
        }

        let subscriptionId = opened.id
        continuation.onTermination = { [weak self] _ in
            Task { await self?.unsubscribe(subscriptionId: subscriptionId) }
        }

        return SubscriptionSequence(
            id: subscriptionId,
            expectedRelays: opened.expectedRelays,
            stream: stream,
            onClose: { [weak self] in
                await self?.unsubscribe(subscriptionId: subscriptionId)
            }
        )
    }

    /// Opens a subscription and returns only its event payloads as an async sequence.
    ///
    /// ```swift
    /// for await event in try await client.events(filters: [filter]) {
    ///     print(event.content)
    /// }
    /// ```
    public func events(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy = .unbounded
    ) async throws -> SubscriptionSequence.Events {
        try await subscribe(filters: filters, to: relayURLs, bufferingPolicy: bufferingPolicy).events
    }

    /// Subscribes to events matching the given filters
    @available(
        *, deprecated,
        message: "Use events(filters:to:bufferingPolicy:) and iterate the returned sequence"
    )
    @discardableResult
    public func subscribe(
        filters: [Filter],
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(filters: filters, to: nil) { subscriptionEvent in
            guard case .event(_, let event) = subscriptionEvent else { return }
            handler(event)
        }.id
    }

    /// Subscribes to events matching the given filters and emits relay-aware subscription events.
    /// Pass `relayURLs` to scope the subscription to a subset of relays (NIP-65 outbox routing);
    /// the default `nil` subscribes on all relays in the pool.
    @available(
        *, deprecated,
        message: "Use subscribe(filters:to:bufferingPolicy:) and iterate the returned SubscriptionSequence"
    )
    @discardableResult
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(filters: filters, to: relayURLs, handler: eventHandler).id
    }

    /// Registers a subscription with the relay pool and routes its messages to `handler`.
    /// Shared core of the stream-based and deprecated closure-based subscribe APIs.
    private func openSubscription(
        filters: [Filter],
        to relayURLs: Set<URL>?,
        handler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> (id: String, expectedRelays: Set<URL>) {
        subscriptionCounter += 1
        let subscriptionId = "sub_\(subscriptionCounter)"

        subscriptions[subscriptionId] = SubscriptionState(
            id: subscriptionId,
            filters: filters,
            handler: handler
        )

        do {
            let expectedRelayURLs = try await relayPool.subscribeWithRelayContext(
                subscriptionId: subscriptionId,
                filters: filters,
                to: relayURLs
            ) { [weak self] relayMessage in
                guard let self else { return }
                await self.handleMessage(
                    relayMessage.message,
                    from: relayMessage.relayURL,
                    subscriptionId: subscriptionId
                )
            }
            return (subscriptionId, expectedRelayURLs)
        } catch {
            subscriptions.removeValue(forKey: subscriptionId)
            // Drop the pool-side handler and message tasks registered before the failure.
            await relayPool.unsubscribe(subscriptionId: subscriptionId)
            throw error
        }
    }

    /// Unsubscribes from a subscription.
    /// No-op for unknown IDs, so the re-entrant call triggered by finishing the
    /// continuation (onTermination → unsubscribe) cannot send a second CLOSE.
    public func unsubscribe(subscriptionId: String) async {
        guard let subscription = subscriptions.removeValue(forKey: subscriptionId) else { return }
        subscription.continuation?.finish()
        await relayPool.unsubscribe(subscriptionId: subscriptionId)
    }

    /// Unsubscribes from all subscriptions
    public func unsubscribeAll() async {
        let active = subscriptions
        subscriptions.removeAll()
        for (subscriptionId, subscription) in active {
            subscription.continuation?.finish()
            await relayPool.unsubscribe(subscriptionId: subscriptionId)
        }
    }

    // MARK: - Convenience Subscriptions

    /// Subscribes to a user's timeline
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.userNotes(pubkey: pubkey, limit: limit)])
    }

    /// Subscribes to the global feed
    public func subscribeToGlobalFeed(
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.globalFeed(limit: limit)])
    }

    /// Subscribes to mentions of a user
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.mentions(pubkey: pubkey, limit: limit)])
    }

    /// Subscribes to metadata updates for a list of pubkeys
    public func subscribeToMetadata(
        pubkeys: [String]
    ) async throws -> SubscriptionSequence {
        try await subscribe(filters: [.metadata(pubkeys: pubkeys)])
    }

    // MARK: - Deprecated Closure-based Convenience Subscriptions

    /// Subscribes to a user's timeline
    @available(*, deprecated, message: "Use subscribeToUserTimeline(pubkey:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.userNotes(pubkey: pubkey, limit: limit)], to: nil,
            handler: Self.eventOnly(handler)
        ).id
    }

    @available(*, deprecated, message: "Use subscribeToUserTimeline(pubkey:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.userNotes(pubkey: pubkey, limit: limit)], to: nil, handler: eventHandler
        ).id
    }

    /// Subscribes to the global feed
    @available(*, deprecated, message: "Use subscribeToGlobalFeed(limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToGlobalFeed(
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.globalFeed(limit: limit)], to: nil, handler: Self.eventOnly(handler)
        ).id
    }

    @available(*, deprecated, message: "Use subscribeToGlobalFeed(limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToGlobalFeed(
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(filters: [.globalFeed(limit: limit)], to: nil, handler: eventHandler).id
    }

    /// Subscribes to mentions of a user
    @available(*, deprecated, message: "Use subscribeToMentions(pubkey:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.mentions(pubkey: pubkey, limit: limit)], to: nil,
            handler: Self.eventOnly(handler)
        ).id
    }

    @available(*, deprecated, message: "Use subscribeToMentions(pubkey:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.mentions(pubkey: pubkey, limit: limit)], to: nil, handler: eventHandler
        ).id
    }

    /// Fetches metadata for a list of pubkeys
    @available(*, deprecated, message: "Use subscribeToMetadata(pubkeys:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToMetadata(
        pubkeys: [String],
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await openSubscription(
            filters: [.metadata(pubkeys: pubkeys)], to: nil, handler: Self.eventOnly(handler)
        ).id
    }

    @available(*, deprecated, message: "Use subscribeToMetadata(pubkeys:) and iterate the returned sequence")
    @discardableResult
    public func subscribeToMetadata(
        pubkeys: [String],
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        try await openSubscription(filters: [.metadata(pubkeys: pubkeys)], to: nil, handler: eventHandler).id
    }

    /// Wraps an event-only handler as a subscription-event handler.
    private static func eventOnly(
        _ handler: @escaping @Sendable (Event) -> Void
    ) -> @Sendable (SubscriptionEvent) -> Void {
        { subscriptionEvent in
            guard case .event(_, let event) = subscriptionEvent else { return }
            handler(event)
        }
    }

    // MARK: - One-time Fetches

    /// Fetches events matching the given filters (one-time)
    /// Waits for all subscribed relays to send EOSE, or until timeout (whichever comes first)
    public func fetch(filters: [Filter], timeout: TimeInterval = 10) async throws -> [Event] {
        let subscription = try await subscribe(filters: filters)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                await subscription.close()
            } catch {
                // Cancelled because fetch finished first: nothing to do.
            }
        }
        defer { timeoutTask.cancel() }

        var eoseTracker = EOSETracker()
        eoseTracker.setExpectedRelays(subscription.expectedRelays)

        var events: [Event] = []
        for await item in subscription {
            switch item {
            case .event(_, let event):
                events.append(event)
            case .eose(let relayURL):
                if eoseTracker.recordEOSE(from: relayURL) {
                    await subscription.close()
                }
            default:
                break
            }
        }

        try Task.checkCancellation()
        return events
    }

    /// Fetches a single event by ID
    public func fetchEvent(id: String, timeout: TimeInterval = 10) async throws -> Event? {
        let filter = Filter(ids: [id])
        let events = try await fetch(filters: [filter], timeout: timeout)
        return events.first
    }

    /// Fetches user metadata
    public func fetchMetadata(pubkey: String, timeout: TimeInterval = 10) async throws -> UserMetadata? {
        let filter = Filter.metadata(pubkeys: [pubkey])
        let events = try await fetch(filters: [filter], timeout: timeout)

        guard let event = events.first else { return nil }

        return try? JSONDecoder().decode(UserMetadata.self, from: Data(event.content.utf8))
    }

    // MARK: - Relay List Metadata & Outbox/Gossip (NIP-65)

    /// Fetches a user's NIP-65 relay list (kind 10002), caching it (newer wins).
    /// - Returns: The relay list, or nil if none was found.
    public func fetchRelayList(for pubkey: String, timeout: TimeInterval = 10) async throws -> RelayListMetadata? {
        let events = try await fetch(filters: [.relayListMetadata(pubkey: pubkey)], timeout: timeout)
        // Replaceable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }),
            let list = newest.relayListMetadata
        else {
            return nil
        }
        await relayListStore.store(list, createdAt: newest.createdAt, for: pubkey)
        return list
    }

    /// Returns the cached relay list for a pubkey without performing a network fetch.
    public func cachedRelayList(for pubkey: String) async -> RelayListMetadata? {
        await relayListStore.cachedList(for: pubkey)
    }

    /// Signs and publishes the current user's relay list metadata (kind 10002, NIP-65).
    /// The list is broadcast to all relays in the pool for discoverability.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        _ relayList: RelayListMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        let event = try signer.signRelayListMetadata(relayList)
        let result = try await relayPool.publish(event, strategy: strategy)
        await relayListStore.store(relayList, createdAt: event.createdAt, for: signer.publicKey)
        return PublishedEvent(event: event, result: result)
    }

    /// Signs and publishes the current user's relay list metadata from read/write relay URLs (NIP-65).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        read: [String] = [],
        write: [String] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        let event = try signer.signRelayListMetadata(read: read, write: write)
        let result = try await relayPool.publish(event, strategy: strategy)
        if let list = event.relayListMetadata {
            await relayListStore.store(list, createdAt: event.createdAt, for: signer.publicKey)
        }
        return PublishedEvent(event: event, result: result)
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    ///
    /// For each author, resolves their WRITE relays (fetching the relay list if not cached),
    /// connects them per the gossip policy, and issues a single subscription scoped to those relays.
    /// If any author has no known relay list, the subscription falls back to the full relay pool so
    /// no author is silently dropped.
    public func subscribeOutbox(
        authors: [String],
        kinds: [Event.Kind] = [.textNote],
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await subscribe(filters: [filter], to: routeSet)
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    /// Convenience overload that delivers only event payloads.
    @available(*, deprecated, message: "Use subscribeOutbox(authors:kinds:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeOutbox(
        authors: [String],
        kinds: [Event.Kind] = [.textNote],
        limit: Int? = nil,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await openSubscription(filters: [filter], to: routeSet, handler: Self.eventOnly(handler)).id
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    @available(*, deprecated, message: "Use subscribeOutbox(authors:kinds:limit:) and iterate the returned sequence")
    @discardableResult
    public func subscribeOutbox(
        authors: [String],
        kinds: [Event.Kind] = [.textNote],
        limit: Int? = nil,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await openSubscription(filters: [filter], to: routeSet, handler: eventHandler).id
    }

    /// Resolves the WRITE relays of the given authors for outbox routing.
    /// - Returns: The connected target set, or `nil` to fall back to the full pool
    ///   when an author is unresolved or nothing could be connected.
    private func resolveOutboxRelays(authors: [String]) async -> Set<URL>? {
        var targets: Set<URL> = []
        var hasUnresolved = false

        for author in authors {
            if await relayListStore.cachedList(for: author) == nil {
                _ = try? await fetchRelayList(for: author)
            }
            let writeURLs = await relayListStore.writeRelayURLs(for: author)
            if writeURLs.isEmpty {
                hasUnresolved = true
            } else {
                targets.formUnion(writeURLs)
            }
        }

        let available = await relayListStore.ensureConnected(targets)
        return (hasUnresolved || available.isEmpty) ? nil : available
    }

    /// Publishes a signed event using the NIP-65 gossip model.
    ///
    /// Routes the event to the author's own WRITE relays plus the READ (inbox) relays of every
    /// pubkey referenced in the event's "p" tags, so mentions and replies reach their recipients.
    /// Falls back to the full relay pool if nothing resolves.
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publishGossip(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        var targets: Set<URL> = []

        if await relayListStore.cachedList(for: event.pubkey) == nil {
            _ = try? await fetchRelayList(for: event.pubkey)
        }
        targets.formUnion(await relayListStore.writeRelayURLs(for: event.pubkey))

        let referencedPubkeys = Set(event.referencedPubkeys)
        for pubkey in referencedPubkeys {
            if await relayListStore.cachedList(for: pubkey) == nil {
                _ = try? await fetchRelayList(for: pubkey)
            }
            targets.formUnion(await relayListStore.readRelayURLs(for: pubkey))
        }

        let available = await relayListStore.ensureConnected(targets)
        return try await relayPool.publish(event, to: available.isEmpty ? nil : available, strategy: strategy)
    }

    // MARK: - Private Methods

    private func handleMessage(_ message: RelayMessage, from relayURL: URL, subscriptionId: String) {
        guard let subscription = subscriptions[subscriptionId] else { return }

        switch message {
        case .event(_, let event):
            // Note: Deduplication is now handled at the RelayPool level
            subscription.handler(.event(relayURL: relayURL, event: event))

        case .endOfStoredEvents:
            subscription.handler(.eose(relayURL: relayURL))

        case .closed(_, let message):
            subscription.handler(.closed(relayURL: relayURL, message: message))

        case .notice(let message):
            subscription.handler(.notice(relayURL: relayURL, message: message))

        case .auth(let challenge):
            subscription.handler(.auth(relayURL: relayURL, challenge: challenge))

        default:
            break
        }
    }

    /// The number of currently registered subscriptions (for tests).
    var activeSubscriptionCount: Int {
        subscriptions.count
    }

    /// Clears the event deduplication cache in the relay pool
    public func clearDeduplicationCache() async {
        await relayPool.clearDeduplicationCache()
    }
}

// MARK: - SubscriptionState
private struct SubscriptionState: Sendable {
    let id: String
    let filters: [Filter]
    let handler: @Sendable (SubscriptionEvent) -> Void

    /// Continuation of the stream backing a ``SubscriptionSequence``;
    /// finished on unsubscribe so iteration ends. `nil` for closure-based subscriptions.
    var continuation: AsyncStream<SubscriptionEvent>.Continuation?

    init(id: String, filters: [Filter], handler: @escaping @Sendable (SubscriptionEvent) -> Void) {
        self.id = id
        self.filters = filters
        self.handler = handler
    }
}
