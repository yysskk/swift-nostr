import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrMessaging {
    /// Sends `template` gift-wrapped, authored under the configured signer's public key and
    /// delivered like a NIP-17 direct message, with no expiration.
    ///
    /// Use it for private payloads other than kinds 14, 15, and 7. To build the gift wraps without
    /// publishing, use ``GiftWrap/wrap(event:signer:recipientPublicKey:expiration:)``.
    /// - Parameters:
    ///   - template: The rumor's kind, tags, content, and creation time.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
    /// - Throws: The errors of
    ///   ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)-(_,_,Timestamp?,_)``.
    @discardableResult
    public func sendGiftWrapped(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(template, to: recipientPublicKey, expiration: nil, strategy: strategy)
    }

    /// Sends `template` gift-wrapped, authored under the configured signer's public key and
    /// delivered like a NIP-17 direct message, with a NIP-40 expiration on both gift wraps.
    /// - Parameters:
    ///   - template: The rumor's kind, tags, content, and creation time.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: When relays stop serving both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
    /// - Throws: The errors of
    ///   ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)-(_,_,Timestamp?,_)``.
    @discardableResult
    public func sendGiftWrapped(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(
            template, to: recipientPublicKey, expiration: Optional(expiration), strategy: strategy)
    }

    /// Subscribes to the current user's messages, reactions, and file messages on the whole pool,
    /// with each relay sending up to 100 stored gift wraps. See
    /// ``NostrMessaging/payloads(limit:)``.
    /// - Returns: The payload sequence.
    public func payloads() async throws -> DirectMessagePayloadSequence {
        try await payloads(limit: 100)
    }

    /// Subscribes to the raw gift wraps addressed to the current user on the whole pool, with each
    /// relay sending up to 100 stored ones. See ``NostrMessaging/giftWraps(limit:)``.
    /// - Returns: The subscription; open each event with ``NostrMessaging/parsePayload(_:)``.
    public func giftWraps() async throws -> SubscriptionSequence {
        try await giftWraps(limit: 100)
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
    /// ``NostrMessaging/sendGiftWrapped(_:to:expiration:strategy:)-(_,_,Timestamp?,_)``.
    /// - Parameters:
    ///   - content: The message text.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - subject: The conversation subject.
    ///   - replyTo: The id of the event replied to.
    ///   - expiration: A NIP-40 expiration for a disappearing message, set on both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``). The
    ///     best-effort self-copy always uses the pool default so it never blocks the send.
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes. The rumor's
    ///   `id` is the key for matching the message when it echoes back from a relay.
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
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
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
    /// by ``EventTemplate/fileMessage(url:mimeType:encryption:size:dimensions:blurhash:to:)``.
    ///
    /// Encrypt the file with ``EncryptedFile/encrypt(_:)`` and upload the resulting
    /// ``EncryptedFile/ciphertext`` to your host first, then pass the URL and the `EncryptedFile`
    /// here. The message carries the URL plus the key, nonce, and hashes the recipient needs to
    /// download and decrypt it.
    /// - Parameters:
    ///   - url: The URL of the uploaded encrypted file.
    ///   - mimeType: The file's MIME type before encryption (e.g. "image/jpeg").
    ///   - encryption: The encryption result from ``EncryptedFile/encrypt(_:)``.
    ///   - size: The encrypted file's size in bytes.
    ///   - dimensions: Pixel dimensions as "<width>x<height>".
    ///   - blurhash: A blurhash placeholder for progressive display.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: A NIP-40 expiration applied to both gift wraps.
    ///   - strategy: How many relay acknowledgments to wait for on the recipient gift wrap before
    ///     returning (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The shared rumor, both gift wraps, and the per-relay publish outcomes.
    @discardableResult
    public func sendFile(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> SendDirectMessageResult {
        try await sendGiftWrapped(
            .fileMessage(
                url: url, mimeType: mimeType, encryption: encryption, size: size, dimensions: dimensions,
                blurhash: blurhash, to: recipientPublicKey),
            to: recipientPublicKey,
            expiration: expiration,
            strategy: strategy
        )
    }

    /// Unwraps a received gift wrap as a direct message (kind 14).
    /// - Parameter giftWrap: The gift-wrapped event.
    /// - Returns: The message.
    /// - Throws: ``DirectMessagePayload/Error/unexpectedKind(_:)`` when the gift wrap carries another
    ///   payload, or the errors of ``NostrMessaging/parsePayload(_:)``.
    public func parse(_ giftWrap: Event) async throws -> DirectMessage {
        let payload = try await parsePayload(giftWrap)
        guard case .message(let message) = payload else {
            throw DirectMessagePayload.Error.unexpectedKind(payload.kind)
        }
        return message
    }

    /// Unwraps a received gift wrap as a NIP-25 reaction to a direct message (kind 7).
    /// - Parameter giftWrap: The gift-wrapped event.
    /// - Returns: The reaction.
    /// - Throws: ``DirectMessagePayload/Error/unexpectedKind(_:)`` when the gift wrap carries another
    ///   payload, or the errors of ``NostrMessaging/parsePayload(_:)``.
    public func parseReaction(_ giftWrap: Event) async throws -> DirectMessageReaction {
        let payload = try await parsePayload(giftWrap)
        guard case .reaction(let reaction) = payload else {
            throw DirectMessagePayload.Error.unexpectedKind(payload.kind)
        }
        return reaction
    }

    /// Unwraps a received gift wrap as a NIP-17 file message (kind 15).
    /// - Parameter giftWrap: The gift-wrapped event.
    /// - Returns: The file message.
    /// - Throws: ``DirectMessagePayload/Error/unexpectedKind(_:)`` when the gift wrap carries another
    ///   payload, or the errors of ``NostrMessaging/parsePayload(_:)``.
    public func parseFile(_ giftWrap: Event) async throws -> DirectMessageFile {
        let payload = try await parsePayload(giftWrap)
        guard case .file(let file) = payload else {
            throw DirectMessagePayload.Error.unexpectedKind(payload.kind)
        }
        return file
    }

    /// Subscribes to the current user's private direct messages (kind 14) on the whole pool,
    /// delivering each message already unwrapped and parsed.
    ///
    /// The messages of ``NostrMessaging/payloads(limit:)``: reactions and file messages on the same
    /// stream are skipped, as are gift wraps that are not readable messages for the signer, while a
    /// signer that could not attempt the read throws out of the iteration — see
    /// ``DirectMessageSequence``. Use ``NostrMessaging/giftWraps(limit:)`` for the raw gift-wrap
    /// events.
    /// - Parameter limit: How many stored gift wraps each relay sends before live ones.
    /// - Returns: The message sequence.
    /// - Throws: The errors of ``NostrMessaging/payloads(limit:)``.
    public func subscribe(limit: Int = 100) async throws -> DirectMessageSequence {
        DirectMessageSequence(messagesOf: try await payloads(limit: limit))
    }
}
