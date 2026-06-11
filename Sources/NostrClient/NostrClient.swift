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
    private var subscriptions: [String: Subscription] = [:]

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
    public func publishTextNote(content: String, tags: [[String]] = []) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let event = try signer.signTextNote(content: content, tags: tags)
        try await relayPool.publish(event)
        return event
    }

    /// Publishes a reply to an event
    public func publishReply(to event: Event, content: String, relayUrl: String? = nil) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        var tags: [[String]] = []

        // Add root and reply markers (NIP-10)
        if let rootTag = event.tags.first(where: { $0.first == "e" && $0.contains("root") }) {
            tags.append(rootTag)
            var replyTag = ["e", event.id]
            if let relayUrl = relayUrl {
                replyTag.append(relayUrl)
            }
            replyTag.append("reply")
            tags.append(replyTag)
        } else {
            // This is a reply to a root event
            var rootTag = ["e", event.id]
            if let relayUrl = relayUrl {
                rootTag.append(relayUrl)
            }
            rootTag.append("root")
            tags.append(rootTag)
        }

        // Add p tag for the author we're replying to
        tags.append(["p", event.pubkey])

        let unsigned = UnsignedEvent(
            pubkey: signer.publicKey,
            kind: .textNote,
            tags: tags,
            content: content
        )

        let signedEvent = try signer.sign(unsigned)
        try await relayPool.publish(signedEvent)
        return signedEvent
    }

    /// Publishes user metadata
    public func publishMetadata(_ metadata: UserMetadata) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let event = try signer.signMetadata(metadata)
        try await relayPool.publish(event)
        return event
    }

    /// Publishes a reaction to an event
    public func publishReaction(to event: Event, content: String = "+") async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let reaction = try signer.signReaction(to: event, content: content)
        try await relayPool.publish(reaction)
        return reaction
    }

    /// Publishes a repost
    public func publishRepost(of event: Event, relayUrl: String? = nil) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let repost = try signer.signRepost(of: event, relayUrl: relayUrl)
        try await relayPool.publish(repost)
        return repost
    }

    /// Publishes a deletion request
    public func publishDeletion(eventIds: [String], reason: String = "") async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }

        let deletion = try signer.signDeletion(eventIds: eventIds, reason: reason)
        try await relayPool.publish(deletion)
        return deletion
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
    /// - Returns: The shared rumor and both gift wraps. The rumor's `id` is the key
    ///   for matching the message when it echoes back from a relay.
    @discardableResult
    public func sendDirectMessage(
        _ content: String,
        to recipientPubkey: String,
        subject: String? = nil,
        replyTo: String? = nil
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

        async let selfCopyDelivery: Void = publishBestEffort(result.selfGiftWrap)
        try await relayPool.publish(result.recipientGiftWrap)
        await selfCopyDelivery

        return result
    }

    /// Publishes an event, swallowing failures (used for non-fatal NIP-17 self-copies).
    private func publishBestEffort(_ event: Event) async {
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

    /// Subscribes to private direct messages for the current user
    /// - Parameters:
    ///   - limit: Maximum number of messages to fetch
    ///   - handler: Handler called for each gift-wrapped event
    /// - Returns: The subscription ID
    @discardableResult
    public func subscribeToDirectMessages(
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeToDirectMessages(
            limit: limit,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    /// Subscribes to private direct messages for the current user.
    /// - Parameters:
    ///   - limit: Maximum number of messages to fetch
    ///   - eventHandler: Handler called for each subscription event
    /// - Returns: The subscription ID
    @discardableResult
    public func subscribeToDirectMessages(
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        guard let publicKey = publicKey else {
            throw NostrError.signingFailed
        }

        // Subscribe to gift-wrapped events addressed to us
        let filter = Filter(
            kinds: [Event.Kind.giftWrap.rawValue],
            pubkeyReferences: [publicKey],
            limit: limit
        )

        return try await subscribe(filters: [filter], eventHandler: eventHandler)
    }

    /// Helper to get the keypair from the signer
    private func getKeyPair() throws -> KeyPair {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        return signer.keyPair
    }

    // MARK: - Subscriptions

    /// Subscribes to events matching the given filters
    @discardableResult
    public func subscribe(
        filters: [Filter],
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribe(
            filters: filters,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    /// Subscribes to events matching the given filters and emits relay-aware subscription events.
    /// Pass `relayURLs` to scope the subscription to a subset of relays (NIP-65 outbox routing);
    /// the default `nil` subscribes on all relays in the pool.
    @discardableResult
    public func subscribe(
        filters: [Filter],
        to relayURLs: Set<URL>? = nil,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        subscriptionCounter += 1
        let subscriptionId = "sub_\(subscriptionCounter)"

        let subscription = Subscription(
            id: subscriptionId,
            filters: filters,
            handler: eventHandler
        )
        subscriptions[subscriptionId] = subscription

        let capturedSubscriptionId = subscriptionId
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
                    subscriptionId: capturedSubscriptionId
                )
            }

            if var subscription = subscriptions[subscriptionId] {
                if subscription.eoseTracker.setExpectedRelays(expectedRelayURLs) {
                    subscription.eoseSignal?.finish()
                    subscription.eoseSignal = nil
                }
                subscriptions[subscriptionId] = subscription
            }
        } catch {
            subscriptions[subscriptionId]?.eoseSignal?.finish()
            subscriptions.removeValue(forKey: subscriptionId)
            throw error
        }

        return subscriptionId
    }

    /// Unsubscribes from a subscription
    public func unsubscribe(subscriptionId: String) async {
        subscriptions[subscriptionId]?.eoseSignal?.finish()
        subscriptions.removeValue(forKey: subscriptionId)
        await relayPool.unsubscribe(subscriptionId: subscriptionId)
    }

    /// Unsubscribes from all subscriptions
    public func unsubscribeAll() async {
        for (_, subscription) in subscriptions {
            subscription.eoseSignal?.finish()
        }
        for subscriptionId in subscriptions.keys {
            await relayPool.unsubscribe(subscriptionId: subscriptionId)
        }
        subscriptions.removeAll()
    }

    // MARK: - Convenience Subscriptions

    /// Subscribes to a user's timeline
    @discardableResult
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeToUserTimeline(
            pubkey: pubkey, limit: limit,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    @discardableResult
    public func subscribeToUserTimeline(
        pubkey: String,
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        let filter = Filter.userNotes(pubkey: pubkey, limit: limit)
        return try await subscribe(filters: [filter], eventHandler: eventHandler)
    }

    /// Subscribes to the global feed
    @discardableResult
    public func subscribeToGlobalFeed(
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeToGlobalFeed(
            limit: limit,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    @discardableResult
    public func subscribeToGlobalFeed(
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        let filter = Filter.globalFeed(limit: limit)
        return try await subscribe(filters: [filter], eventHandler: eventHandler)
    }

    /// Subscribes to mentions of a user
    @discardableResult
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeToMentions(
            pubkey: pubkey, limit: limit,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    @discardableResult
    public func subscribeToMentions(
        pubkey: String,
        limit: Int = 100,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        let filter = Filter.mentions(pubkey: pubkey, limit: limit)
        return try await subscribe(filters: [filter], eventHandler: eventHandler)
    }

    /// Fetches metadata for a list of pubkeys
    @discardableResult
    public func subscribeToMetadata(
        pubkeys: [String],
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeToMetadata(
            pubkeys: pubkeys,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    @discardableResult
    public func subscribeToMetadata(
        pubkeys: [String],
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
        let filter = Filter.metadata(pubkeys: pubkeys)
        return try await subscribe(filters: [filter], eventHandler: eventHandler)
    }

    // MARK: - One-time Fetches

    /// Fetches events matching the given filters (one-time)
    /// Waits for all subscribed relays to send EOSE, or until timeout (whichever comes first)
    public func fetch(filters: [Filter], timeout: TimeInterval = 10) async throws -> [Event] {
        let collectedEvents = EventCollector()

        let subscriptionId = try await subscribe(
            filters: filters,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                Task {
                    await collectedEvents.append(event)
                }
            })

        let (eoseStream, eoseContinuation) = AsyncStream.makeStream(of: Void.self)
        installEOSESignal(for: subscriptionId, continuation: eoseContinuation)

        do {
            // Race all-relay EOSE vs timeout
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in eoseStream { break }
                }

                group.addTask {
                    try? await Task.sleep(for: .seconds(timeout))
                }

                await group.next()
                group.cancelAll()
            }

            if Task.isCancelled {
                throw CancellationError()
            }

            await unsubscribe(subscriptionId: subscriptionId)
            return await collectedEvents.events
        } catch {
            await unsubscribe(subscriptionId: subscriptionId)
            throw error
        }
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
    @discardableResult
    public func publishRelayList(_ relayList: RelayListMetadata) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        let event = try signer.signRelayListMetadata(relayList)
        try await relayPool.publish(event)
        await relayListStore.store(relayList, createdAt: event.createdAt, for: signer.publicKey)
        return event
    }

    /// Signs and publishes the current user's relay list metadata from read/write relay URLs (NIP-65).
    @discardableResult
    public func publishRelayList(read: [String] = [], write: [String] = []) async throws -> Event {
        guard let signer = signer else {
            throw NostrError.signingFailed
        }
        let event = try signer.signRelayListMetadata(read: read, write: write)
        try await relayPool.publish(event)
        if let list = event.relayListMetadata {
            await relayListStore.store(list, createdAt: event.createdAt, for: signer.publicKey)
        }
        return event
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    /// Convenience overload that delivers only event payloads.
    @discardableResult
    public func subscribeOutbox(
        authors: [String],
        kinds: [Int] = [Event.Kind.textNote.rawValue],
        limit: Int? = nil,
        handler: @escaping @Sendable (Event) -> Void
    ) async throws -> String {
        try await subscribeOutbox(
            authors: authors, kinds: kinds, limit: limit,
            eventHandler: { subscriptionEvent in
                guard case .event(_, let event) = subscriptionEvent else { return }
                handler(event)
            })
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    ///
    /// For each author, resolves their WRITE relays (fetching the relay list if not cached),
    /// connects them per the gossip policy, and issues a single subscription scoped to those relays.
    /// If any author has no known relay list, the subscription falls back to the full relay pool so
    /// no author is silently dropped.
    @discardableResult
    public func subscribeOutbox(
        authors: [String],
        kinds: [Int] = [Event.Kind.textNote.rawValue],
        limit: Int? = nil,
        eventHandler: @escaping @Sendable (SubscriptionEvent) -> Void
    ) async throws -> String {
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
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        // Fall back to the full pool when an author is unresolved or nothing could be connected.
        let routeSet: Set<URL>? = (hasUnresolved || available.isEmpty) ? nil : available
        return try await subscribe(filters: [filter], to: routeSet, eventHandler: eventHandler)
    }

    /// Publishes a signed event using the NIP-65 gossip model.
    ///
    /// Routes the event to the author's own WRITE relays plus the READ (inbox) relays of every
    /// pubkey referenced in the event's "p" tags, so mentions and replies reach their recipients.
    /// Falls back to the full relay pool if nothing resolves.
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publishGossip(_ event: Event) async throws -> PublishResult {
        var targets: Set<URL> = []

        if await relayListStore.cachedList(for: event.pubkey) == nil {
            _ = try? await fetchRelayList(for: event.pubkey)
        }
        targets.formUnion(await relayListStore.writeRelayURLs(for: event.pubkey))

        let referencedPubkeys = Set(event.tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] })
        for pubkey in referencedPubkeys {
            if await relayListStore.cachedList(for: pubkey) == nil {
                _ = try? await fetchRelayList(for: pubkey)
            }
            targets.formUnion(await relayListStore.readRelayURLs(for: pubkey))
        }

        let available = await relayListStore.ensureConnected(targets)
        return try await relayPool.publish(event, to: available.isEmpty ? nil : available)
    }

    // MARK: - Private Methods

    private func handleMessage(_ message: RelayMessage, from relayURL: URL, subscriptionId: String) {
        guard var subscription = subscriptions[subscriptionId] else { return }

        switch message {
        case .event(_, let event):
            // Note: Deduplication is now handled at the RelayPool level
            subscription.handler(.event(relayURL: relayURL, event: event))

        case .endOfStoredEvents:
            subscription.handler(.eose(relayURL: relayURL))
            if subscription.eoseTracker.recordEOSE(from: relayURL) {
                subscription.eoseSignal?.finish()
                subscription.eoseSignal = nil
            }

        case .closed(_, let message):
            subscription.handler(.closed(relayURL: relayURL, message: message))

        case .notice(let message):
            subscription.handler(.notice(relayURL: relayURL, message: message))

        case .auth(let challenge):
            subscription.handler(.auth(relayURL: relayURL, challenge: challenge))

        default:
            break
        }

        subscriptions[subscriptionId] = subscription
    }

    private func installEOSESignal(
        for subscriptionId: String,
        continuation: AsyncStream<Void>.Continuation
    ) {
        guard var subscription = subscriptions[subscriptionId] else {
            continuation.finish()
            return
        }

        if subscription.eoseTracker.isComplete {
            continuation.finish()
            return
        }

        subscription.eoseSignal = continuation
        subscriptions[subscriptionId] = subscription
    }

    /// Clears the event deduplication cache in the relay pool
    public func clearDeduplicationCache() async {
        await relayPool.clearDeduplicationCache()
    }
}

// MARK: - Subscription
private struct Subscription: Sendable {
    let id: String
    let filters: [Filter]
    let handler: @Sendable (SubscriptionEvent) -> Void
    var eoseTracker = EOSETracker()
    var eoseSignal: AsyncStream<Void>.Continuation?

    init(id: String, filters: [Filter], handler: @escaping @Sendable (SubscriptionEvent) -> Void) {
        self.id = id
        self.filters = filters
        self.handler = handler
    }
}

// MARK: - Event Collector for thread-safe event collection
private actor EventCollector {
    var events: [Event] = []

    func append(_ event: Event) {
        events.append(event)
    }
}
