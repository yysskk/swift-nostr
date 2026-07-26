import Foundation
import NostrCore

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
    /// copy falls back to the full relay pool rather than being dropped; the recipient copy's
    /// fallback throws ``NostrError/noRelaysInPool`` when the pool is also empty, while the
    /// self-copy stays best-effort.
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
        let result = try await withSigner { signer, _ in
            try await DirectMessageBuilder(signer: signer).createMessageWithSelfCopy(
                content: content,
                to: recipientPubkey,
                subject: subject,
                replyTo: replyTo,
                expiration: expiration
            )
        }

        return try await deliverDirectMessage(result, to: recipientPubkey, strategy: strategy)
    }

    /// Sends a NIP-25 reaction to a received direct message, gift-wrapped like the message itself.
    ///
    /// The reaction (an unsigned kind-7 rumor) references the message's rumor id and author, and is
    /// delivered to the message author's NIP-17 DM relays plus the sender's own self-copy — the same
    /// routing as ``sendDirectMessage(_:to:subject:replyTo:expiration:strategy:)``.
    /// - Parameters:
    ///   - message: The message being reacted to. Its author receives the reaction.
    ///   - reaction: The reaction content (default "+", a NIP-25 like). Use "-" or an emoji.
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
    @discardableResult
    public func reactToDirectMessage(
        _ message: DirectMessage,
        reaction: String = "+",
        expiration: Date? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        let result = try await withSigner { signer, _ in
            try await DirectMessageBuilder(signer: signer).createReactionWithSelfCopy(
                reaction: reaction,
                to: message.rumorId,
                author: message.senderPubkey,
                recipientPubkey: message.senderPubkey,
                expiration: expiration
            )
        }

        return try await deliverDirectMessage(result, to: message.senderPubkey, strategy: strategy)
    }

    /// Sends a NIP-17 kind-15 file message, gift-wrapped and routed like a text message.
    ///
    /// Encrypt the file with ``EncryptedFile/encrypt(_:)`` and upload the resulting
    /// ``EncryptedFile/ciphertext`` to your host first, then pass the URL and the `EncryptedFile`
    /// here. The message carries the URL plus the key, nonce, and hashes the recipient needs to
    /// download and decrypt it.
    /// - Parameters:
    ///   - url: The URL of the uploaded encrypted file.
    ///   - mimeType: The file's MIME type before encryption (e.g. "image/jpeg").
    ///   - encryption: The encryption result from ``EncryptedFile/encrypt(_:)``.
    ///   - size: Optional size of the encrypted file in bytes.
    ///   - dimensions: Optional pixel dimensions as "<width>x<height>".
    ///   - blurhash: Optional blurhash placeholder for progressive display.
    ///   - recipientPubkey: The recipient's public key (hex).
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
    @discardableResult
    public func sendFileMessage(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        to recipientPubkey: String,
        expiration: Date? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        let result = try await withSigner { signer, _ in
            try await DirectMessageBuilder(signer: signer).createFileMessageWithSelfCopy(
                url: url,
                mimeType: mimeType,
                encryption: encryption,
                size: size,
                dimensions: dimensions,
                blurhash: blurhash,
                to: recipientPubkey,
                expiration: expiration
            )
        }

        return try await deliverDirectMessage(result, to: recipientPubkey, strategy: strategy)
    }

    /// Routes a built result's gift wraps to the recipient's and sender's kind-10050 DM relays and
    /// publishes them, returning the result enriched with per-relay outcomes. Shared by the message,
    /// reaction, and file send paths.
    ///
    /// A nil target means the addressee advertised no DM relay list (or none could be connected), so
    /// the copy falls back to the full pool rather than being dropped; the recipient copy's fallback
    /// throws ``NostrError/noRelaysInPool`` when the pool is also empty. The recipient and sender
    /// addressees are resolved in parallel — each may trigger an independent relay-list fetch — and
    /// the best-effort self-copy never blocks or fails the primary send.
    private func deliverDirectMessage(
        _ result: SendDirectMessageResult,
        to recipientPubkey: String,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult {
        async let recipientTargetsTask = directMessageInboxTargets(for: recipientPubkey)
        // The rumor is authored under the sender's key, so it names the self-copy's addressee.
        async let senderTargetsTask = directMessageInboxTargets(for: result.rumor.pubkey)
        let recipientTargets = await recipientTargetsTask
        let senderTargets = await senderTargetsTask

        async let selfCopyDelivery = publishBestEffort(result.selfGiftWrap, toURLs: senderTargets)
        let recipientResult = try await relayPool.publish(
            result.recipientGiftWrap, toURLs: recipientTargets, strategy: strategy
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
    /// - Parameter relayURLs: The canonical relays to target, or nil to broadcast to the full pool.
    /// - Returns: The per-relay outcome, or nil if the publish failed outright.
    private func publishBestEffort(_ event: Event, toURLs relayURLs: Set<URL>?) async -> PublishResult? {
        try? await relayPool.publish(event, toURLs: relayURLs, strategy: nil)
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
    public func parseDirectMessage(_ giftWrap: Event) async throws -> DirectMessage {
        try await withSigner { signer, _ in
            try await DirectMessageParser(signer: signer).parse(giftWrap)
        }
    }

    /// Parses a received gift-wrapped NIP-25 reaction to a direct message.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed reaction
    public func parseDirectMessageReaction(_ giftWrap: Event) async throws -> DirectMessageReaction {
        try await withSigner { signer, _ in
            try await DirectMessageParser(signer: signer).parseReaction(giftWrap)
        }
    }

    /// Parses a received gift-wrapped NIP-17 kind-15 file message.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed file message
    public func parseDirectMessageFile(_ giftWrap: Event) async throws -> DirectMessageFile {
        try await withSigner { signer, _ in
            try await DirectMessageParser(signer: signer).parseFileMessage(giftWrap)
        }
    }

    /// Parses a received gift wrap into a ``DirectMessagePayload`` — a message, a reaction, or a file.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The decrypted payload
    public func parseDirectMessagePayload(_ giftWrap: Event) async throws -> DirectMessagePayload {
        try await withSigner { signer, _ in
            try await DirectMessageParser(signer: signer).parsePayload(giftWrap)
        }
    }

    /// Subscribes to the current user's private direct messages (NIP-17),
    /// delivering each message already unwrapped and parsed.
    ///
    /// Gift wraps that are not readable messages for the signer are skipped, while a signer that
    /// could not attempt the read throws out of the iteration — see ``DirectMessageSequence``. Use
    /// ``subscribeToDirectMessages(limit:)`` for the raw gift-wrap events.
    /// - Parameter limit: Maximum number of messages to fetch
    public func directMessages(limit: Int = 100) async throws -> DirectMessageSequence {
        let parser = try await directMessageParser()
        let subscription = try await subscribe(filters: [directMessagesFilter(limit: limit)])
        return DirectMessageSequence(base: subscription, parser: parser)
    }

    /// Subscribes to the current user's direct messages **and** reactions (NIP-17 + NIP-25),
    /// delivering each gift wrap already unwrapped and classified as a ``DirectMessagePayload``.
    ///
    /// Use this instead of ``directMessages(limit:)`` when you also want reactions; messages and
    /// reactions share the same kind-1059 gift-wrap stream. Unreadable gift wraps are skipped and
    /// signer failures throw, as in ``DirectMessageSequence``.
    /// - Parameter limit: Maximum number of gift wraps to fetch
    public func directMessagePayloads(limit: Int = 100) async throws -> DirectMessagePayloadSequence {
        let parser = try await directMessageParser()
        let subscription = try await subscribe(filters: [directMessagesFilter(limit: limit)])
        return DirectMessagePayloadSequence(base: subscription, parser: parser)
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

    /// A parser bound to the active signer, for the sequences that keep unwrapping messages as
    /// they arrive. Deliberately lets the signer outlive the call: a live sequence needs it for
    /// the subscription's whole lifetime.
    private func directMessageParser() async throws -> DirectMessageParser {
        try await withSigner { signer, _ in DirectMessageParser(signer: signer) }
    }
}
