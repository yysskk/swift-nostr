import Foundation

// MARK: - Private Direct Messages (NIP-17)
extension NostrClient {
    /// Sends a private direct message to a recipient using NIP-17.
    ///
    /// One unsigned kind-14 rumor is wrapped twice: once for the recipient and once
    /// for the sender (the NIP-17 self-copy that provides sent history and
    /// multi-device sync). Both gift wraps are published in parallel; the message
    /// succeeds when the recipient copy is accepted, and a failed self-copy publish
    /// is non-fatal.
    ///
    /// Each gift wrap is routed to its addressee's NIP-17 DM relays (kind 10050): the recipient
    /// copy to the recipient's inbox relays and the self-copy to the sender's own, discovering
    /// and caching the lists as needed. When an addressee has advertised no DM relay list, that
    /// copy falls back to the full relay pool rather than being dropped.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPubkey: The recipient's public key (hex)
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional event ID to reply to
    ///   - expiration: Optional NIP-40 expiration for a disappearing message. Set on both gift
    ///     wraps (the stored kind-1059 events) so relays stop serving the message after this time.
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
        expiration: Date? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        let keyPair = try getKeyPair()

        let builder = DirectMessageBuilder(keyPair: keyPair)
        let result = try builder.createMessageWithSelfCopy(
            content: content,
            to: recipientPubkey,
            subject: subject,
            replyTo: replyTo,
            expiration: expiration
        )

        // NIP-17 routing: deliver each gift wrap to its addressee's kind-10050 DM inbox relays.
        // A nil target means the addressee advertised no DM relay list (or none could be
        // connected), so fall back to the full pool rather than dropping the message.
        // Resolve both addressees in parallel — each may trigger an independent relay-list fetch.
        async let recipientTargetsTask = directMessageInboxTargets(for: recipientPubkey)
        async let senderTargetsTask = directMessageInboxTargets(for: keyPair.publicKeyHex)
        let recipientTargets = await recipientTargetsTask
        let senderTargets = await senderTargetsTask

        async let selfCopyDelivery = publishBestEffort(result.selfGiftWrap, to: senderTargets)
        let recipientResult = try await relayPool.publish(
            result.recipientGiftWrap, to: recipientTargets, strategy: strategy
        )
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
    /// - Parameter relayURLs: The relays to target, or nil to broadcast to the full pool.
    /// - Returns: The per-relay outcome, or nil if the publish failed outright.
    private func publishBestEffort(_ event: Event, to relayURLs: Set<URL>? = nil) async -> PublishResult? {
        try? await relayPool.publish(event, to: relayURLs)
    }

    /// Resolves the kind-10050 DM inbox relays to route a gift wrap to for `pubkey`, connecting
    /// them per the gossip policy.
    /// - Returns: The connected inbox relays, or nil when the addressee advertised no DM relay
    ///   list (or none could be connected) — signalling a fall back to the full relay pool.
    private func directMessageInboxTargets(for pubkey: String) async -> Set<URL>? {
        let connected = await connectedDirectMessageInboxRelays(for: pubkey)
        return connected.isEmpty ? nil : connected
    }

    /// Parses a received gift-wrapped direct message
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed DirectMessage
    public func parseDirectMessage(_ giftWrap: Event) throws -> DirectMessage {
        let keyPair = try getKeyPair()

        let parser = DirectMessageParser(keyPair: keyPair)
        return try parser.parse(giftWrap)
    }

    /// Subscribes to the current user's private direct messages (NIP-17),
    /// delivering each message already unwrapped and parsed.
    ///
    /// Gift wraps that fail to unwrap or parse are skipped; use
    /// ``subscribeToDirectMessages(limit:)`` for the raw gift-wrap events.
    /// - Parameter limit: Maximum number of messages to fetch
    public func directMessages(limit: Int = 100) async throws -> DirectMessageSequence {
        let keyPair = try getKeyPair()
        let subscription = try await subscribe(filters: [directMessagesFilter(limit: limit)])
        return DirectMessageSequence(base: subscription, parser: DirectMessageParser(keyPair: keyPair))
    }

    /// Subscribes to private direct messages (gift-wrapped events) for the current user.
    /// - Parameter limit: Maximum number of messages to fetch
    /// - Returns: A subscription sequence of gift-wrapped events; parse each with
    ///   ``parseDirectMessage(_:)`` — or use ``directMessages(limit:)`` to receive
    ///   them already parsed.
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
            throw NostrError.signerNotSet
        }
        return Filter(
            kinds: [.giftWrap],
            pubkeyReferences: [publicKey],
            limit: limit
        )
    }

    /// Helper to get the keypair from the signer
    private func getKeyPair() throws -> KeyPair {
        try withSigner { $0.keyPair }
    }
}
