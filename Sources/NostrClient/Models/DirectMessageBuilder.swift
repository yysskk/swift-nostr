import Foundation

/// Builder for creating NIP-17 direct message events
public struct DirectMessageBuilder: Sendable {
    private let senderKeyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.senderKeyPair = keyPair
    }

    /// Creates the recipient gift wrap and the sender's self-copy from one shared rumor.
    ///
    /// NIP-17 sends every message twice — once wrapped for the recipient and once
    /// wrapped for the sender — so the sender's other devices can reconstruct the
    /// conversation. Both wraps carry the identical unsigned rumor; its `id` is the
    /// key for matching the message when it echoes back from a relay.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPubkey: The recipient's public key (hex)
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional event ID to reply to
    ///   - expiration: Optional NIP-40 expiration for a disappearing message. Applied to both
    ///     gift wraps so the recipient and self copies expire together.
    /// - Returns: The shared rumor and both gift wraps
    public func createMessageWithSelfCopy(
        content: String,
        to recipientPubkey: String,
        subject: String? = nil,
        replyTo: String? = nil,
        expiration: Date? = nil
    ) throws -> SendDirectMessageResult {
        let rumor = try makeRumor(
            content: content,
            tags: directMessageTags(recipientPubkey: recipientPubkey, subject: subject, replyTo: replyTo)
        )
        return try wrapWithSelfCopy(rumor: rumor, to: recipientPubkey, expiration: expiration)
    }

    /// Creates a gift-wrapped NIP-25 reaction to a direct message, plus the sender's self-copy.
    ///
    /// The reaction is an unsigned kind-7 rumor referencing the target message's rumor id and
    /// author. Like a message it is wrapped twice — for the recipient and for the sender — so it
    /// stays private and sender-anonymous, and both wraps carry the identical rumor.
    /// - Parameters:
    ///   - reaction: The reaction content. NIP-25 uses "+" for a like, "-" for a dislike, or an
    ///     emoji such as "🤙".
    ///   - messageId: The rumor id of the message being reacted to (the reaction's "e" tag).
    ///   - author: The reacted-to message's author public key (the reaction's "p" tag).
    ///   - recipientPubkey: Who receives the reaction gift wrap (typically the message author).
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    /// - Returns: The shared rumor and both gift wraps.
    public func createReactionWithSelfCopy(
        reaction: String = "+",
        to messageId: String,
        author: String,
        recipientPubkey: String,
        expiration: Date? = nil
    ) throws -> SendDirectMessageResult {
        let rumor = try makeReactionRumor(reaction: reaction, messageId: messageId, author: author)
        return try wrapWithSelfCopy(rumor: rumor, to: recipientPubkey, expiration: expiration)
    }

    /// Creates a gift-wrapped NIP-17 kind-15 file message, plus the sender's self-copy.
    ///
    /// The file must already be encrypted (see ``EncryptedFile/encrypt(_:)``) and uploaded; pass
    /// the resulting URL and ``EncryptedFile``. The message carries the URL as its content and the
    /// key, nonce, and hashes as tags, wrapped exactly like a text message so it stays private.
    /// - Parameters:
    ///   - url: The URL of the uploaded encrypted file.
    ///   - mimeType: The file's MIME type before encryption (the `file-type` tag).
    ///   - encryption: The encryption result whose key, nonce, and hashes describe the file.
    ///   - size: Optional size of the encrypted file in bytes (the `size` tag).
    ///   - dimensions: Optional pixel dimensions as "<width>x<height>" (the `dim` tag).
    ///   - blurhash: Optional blurhash placeholder (the `blurhash` tag).
    ///   - recipientPubkey: The recipient's public key (hex).
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    /// - Returns: The shared rumor and both gift wraps.
    public func createFileMessageWithSelfCopy(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        to recipientPubkey: String,
        expiration: Date? = nil
    ) throws -> SendDirectMessageResult {
        let rumor = try makeFileRumor(
            url: url, mimeType: mimeType, encryption: encryption, recipientPubkey: recipientPubkey,
            size: size, dimensions: dimensions, blurhash: blurhash)
        return try wrapWithSelfCopy(rumor: rumor, to: recipientPubkey, expiration: expiration)
    }

    /// Creates gift-wrapped events for a group message (sends to multiple recipients)
    /// Each recipient gets their own gift-wrapped copy
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPubkeys: The recipients' public keys (hex)
    ///   - subject: Optional conversation subject
    /// - Returns: Array of gift-wrapped events, one for each recipient plus the sender's copy
    public func createGroupMessage(
        content: String,
        to recipientPubkeys: [String],
        subject: String? = nil
    ) throws -> [Event] {
        // Build tags with all recipients
        var tags: [Tag] = recipientPubkeys.map { Tag.pubkey($0) }

        if let subject = subject {
            tags.append(.subject(subject))
        }

        let rumor = try makeRumor(content: content, tags: tags)

        // Gift wrap for each recipient (including sender for their copy)
        var giftWraps: [Event] = []

        for recipientPubkey in recipientPubkeys {
            let wrapped = try GiftWrap.wrap(
                event: rumor,
                senderKeyPair: senderKeyPair,
                recipientPubkey: recipientPubkey
            )
            giftWraps.append(wrapped)
        }

        // Also create a copy for the sender
        let senderCopy = try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: senderKeyPair.publicKeyHex
        )
        giftWraps.append(senderCopy)

        return giftWraps
    }

    // MARK: - Private Helpers

    /// Wraps a shared rumor twice — once for the recipient and once for the sender's self-copy —
    /// and packages both with the rumor.
    ///
    /// NIP-17 delivers every message to both parties so the sender's other devices can reconstruct
    /// the conversation; both wraps carry the identical rumor, whose `id` keys the two copies
    /// together. Any NIP-40 `expiration` is applied to both wraps so the copies expire in lockstep.
    private func wrapWithSelfCopy(
        rumor: Event,
        to recipientPubkey: String,
        expiration: Date?
    ) throws -> SendDirectMessageResult {
        let recipientGiftWrap = try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: recipientPubkey,
            expiration: expiration
        )
        let selfGiftWrap = try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: senderKeyPair.publicKeyHex,
            expiration: expiration
        )

        return SendDirectMessageResult(
            rumor: rumor,
            recipientGiftWrap: recipientGiftWrap,
            selfGiftWrap: selfGiftWrap
        )
    }

    /// Builds the NIP-17 tag list for a 1-to-1 direct message
    private func directMessageTags(
        recipientPubkey: String,
        subject: String?,
        replyTo: String?
    ) -> [Tag] {
        var tags: [Tag] = [
            .pubkey(recipientPubkey)
        ]

        if let subject = subject {
            tags.append(.subject(subject))
        }

        if let replyTo = replyTo {
            tags.append(.event(replyTo, marker: .reply))
        }

        return tags
    }

    /// Creates the unsigned kind-14 rumor with its id computed.
    /// The rumor is deliberately never signed (NIP-17: a leaked signed rumor would
    /// be cryptographic proof of authorship and destroy deniability).
    private func makeRumor(content: String, tags: [Tag]) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: senderKeyPair.publicKeyHex,
            kind: .privateDirectMessage,
            tags: tags,
            content: content
        )
        return try unsigned.asRumor()
    }

    /// Creates the unsigned kind-7 reaction rumor. Like the message rumor it is never signed.
    private func makeReactionRumor(reaction: String, messageId: String, author: String) throws -> Event {
        let tags: [Tag] = [
            .event(messageId),
            .pubkey(author),
            .kind(.privateDirectMessage),
        ]
        let unsigned = UnsignedEvent(
            pubkey: senderKeyPair.publicKeyHex,
            kind: .reaction,
            tags: tags,
            content: reaction
        )
        return try unsigned.asRumor()
    }

    /// Creates the unsigned kind-15 file-message rumor. Like the message rumor it is never signed.
    /// The content is the file URL; the key, nonce, and hashes are carried as tags.
    private func makeFileRumor(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        recipientPubkey: String,
        size: Int?,
        dimensions: String?,
        blurhash: String?
    ) throws -> Event {
        var tags: [Tag] = [
            .pubkey(recipientPubkey),
            Tag(name: "file-type", values: [mimeType]),
            Tag(name: "encryption-algorithm", values: ["aes-gcm"]),
            Tag(name: "decryption-key", values: [encryption.key.base64EncodedString()]),
            Tag(name: "decryption-nonce", values: [encryption.nonce.base64EncodedString()]),
            Tag(name: "x", values: [encryption.encryptedSHA256]),
            Tag(name: "ox", values: [encryption.originalSHA256]),
        ]
        if let size {
            tags.append(Tag(name: "size", values: [String(size)]))
        }
        if let dimensions {
            tags.append(Tag(name: "dim", values: [dimensions]))
        }
        if let blurhash {
            tags.append(Tag(name: "blurhash", values: [blurhash]))
        }

        let unsigned = UnsignedEvent(
            pubkey: senderKeyPair.publicKeyHex,
            kind: .fileMessage,
            tags: tags,
            content: url
        )
        return try unsigned.asRumor()
    }
}
