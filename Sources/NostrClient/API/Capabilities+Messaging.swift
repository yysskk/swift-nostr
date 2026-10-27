import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrMessaging {
    /// Sends `template` gift-wrapped, authored under the configured signer's public key and
    /// delivered like a NIP-17 direct message, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``.
    ///
    /// Use it for private payloads other than kinds 14, 15, and 7. To build a gift wrap without
    /// publishing, use ``GiftWrap/wrap(_:signer:to:expiration:)``.
    /// - Parameters:
    ///   - template: The rumor's kind, tags, content, and creation time.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: A NIP-40 expiration set on both gift wraps, if any.
    /// - Returns: The published ``GiftWrappedMessage`` and the per-relay publish outcomes.
    /// - Throws: The errors of ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)``.
    @discardableResult
    public func sendGiftWrapped(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(template, to: recipientPublicKey, expiration: expiration, strategy: nil)
    }

    /// Subscribes to the current user's gift wraps on the whole pool, with each relay sending up to
    /// 100 stored ones. See ``NostrMessaging/subscribe(limit:)``.
    ///
    /// ```swift
    /// for try await message in try await client.messages.subscribe().messages {
    ///     print("\(message.senderPublicKey): \(message.content)")
    /// }
    /// ```
    /// - Returns: The payload sequence.
    public func subscribe() async throws -> DirectMessagePayloadSequence {
        try await subscribe(limit: 100)
    }
}

// MARK: - Conveniences

extension NostrMessaging {
    /// Sends a private direct message (kind 14) using NIP-17, built by
    /// ``EventTemplate/directMessage(_:to:subject:replyTo:)``.
    ///
    /// One unsigned rumor is wrapped twice: once for the recipient and once for the sender (the
    /// NIP-17 self-copy that provides sent history and multi-device sync), each routed to its
    /// addressee's DM relays — see
    /// ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)``.
    /// - Parameters:
    ///   - content: The message text.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - subject: The conversation subject.
    ///   - replyTo: The id of the event replied to.
    ///   - expiration: A NIP-40 expiration for a disappearing message, set on both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``). The
    ///     best-effort self-copy always uses the pool default so it never blocks the send.
    /// - Returns: The published ``GiftWrappedMessage`` and the per-relay publish outcomes. Its
    ///   `message.rumor.id` is the key for matching the message when it echoes back from a relay.
    @discardableResult
    public func send(
        _ content: String,
        to recipientPublicKey: PublicKey,
        subject: String? = nil,
        replyTo: EventID? = nil,
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(
            .directMessage(content, to: recipientPublicKey, subject: subject, replyTo: replyTo),
            to: recipientPublicKey,
            expiration: expiration,
            strategy: strategy
        )
    }

    /// Sends a NIP-25 reaction to a received direct message, gift-wrapped like the message itself
    /// and built by ``EventTemplate/directMessageReaction(to:author:content:)``.
    ///
    /// The reaction is delivered to the message author's DM relays plus the sender's own self-copy —
    /// the same routing as ``NostrMessaging/send(_:to:subject:replyTo:expiration:strategy:)``.
    /// - Parameters:
    ///   - message: The message reacted to. Its author receives the reaction.
    ///   - reaction: The reaction content (default "+", a NIP-25 like). Use "-" or an emoji.
    ///   - expiration: A NIP-40 expiration applied to both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The published ``GiftWrappedMessage`` and the per-relay publish outcomes.
    @discardableResult
    public func react(
        to message: DirectMessage,
        reaction: String = "+",
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(
            .directMessageReaction(to: message.rumorID, author: message.senderPublicKey, content: reaction),
            to: message.senderPublicKey,
            expiration: expiration,
            strategy: strategy
        )
    }

    /// Sends a NIP-17 file message (kind 15), gift-wrapped and routed like a text message and built
    /// by ``EventTemplate/fileMessage(_:to:)``.
    ///
    /// Encrypt the file with ``EncryptedFile/encrypt(_:)`` and upload the resulting
    /// ``EncryptedFile/ciphertext`` to your host first, then describe it with
    /// ``FileAttachment/init(url:mimeType:encryption:size:dimensions:blurhash:)``. The message
    /// carries the URL plus the key, nonce, and hashes the recipient needs to download and decrypt it.
    /// - Parameters:
    ///   - attachment: The uploaded encrypted file.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: A NIP-40 expiration applied to both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The published ``GiftWrappedMessage`` and the per-relay publish outcomes.
    @discardableResult
    public func sendFile(
        _ attachment: FileAttachment,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(
            .fileMessage(attachment, to: recipientPublicKey),
            to: recipientPublicKey,
            expiration: expiration,
            strategy: strategy
        )
    }
}
