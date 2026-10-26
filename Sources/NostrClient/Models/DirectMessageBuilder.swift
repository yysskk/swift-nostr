import Foundation
import NostrCore

/// Builder for creating NIP-17 direct message events.
///
/// Takes any ``NostrSigning`` — a local key or a remote NIP-46 signer — because
/// everything it needs from the sender's identity (NIP-44 sealing and signing the seal) is part
/// of that abstraction.
public struct DirectMessageBuilder: Sendable {
    private let signer: any NostrSigning

    /// Creates a builder that authors and seals messages as `signer`'s identity.
    public init(signer: any NostrSigning) {
        self.signer = signer
    }

    /// Creates the recipient gift wrap and the sender's self-copy from one shared rumor.
    ///
    /// NIP-17 sends every message twice — once wrapped for the recipient and once
    /// wrapped for the sender — so the sender's other devices can reconstruct the
    /// conversation. Both wraps carry the identical unsigned rumor; its `id` is the
    /// key for matching the message when it echoes back from a relay.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPublicKey: The recipient's public key
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional id of the event to reply to
    ///   - expiration: Optional NIP-40 expiration for a disappearing message. Applied to both
    ///     gift wraps so the recipient and self copies expire together.
    /// - Returns: The shared rumor and both gift wraps
    public func createMessageWithSelfCopy(
        content: String,
        to recipientPublicKey: PublicKey,
        subject: String? = nil,
        replyTo: EventID? = nil,
        expiration: Timestamp? = nil
    ) async throws -> SendDirectMessageResult {
        let senderPublicKey = try await signer.publicKey
        let rumor = try makeRumor(
            senderPublicKey: senderPublicKey,
            content: content,
            tags: directMessageTags(recipientPublicKey: recipientPublicKey, subject: subject, replyTo: replyTo)
        )
        return try await wrapWithSelfCopy(
            rumor: rumor, senderPublicKey: senderPublicKey, to: recipientPublicKey, expiration: expiration)
    }

    /// Creates a gift-wrapped NIP-25 reaction to a direct message, plus the sender's self-copy.
    ///
    /// The reaction is an unsigned kind-7 rumor referencing the target message's rumor id and
    /// author. Like a message it is wrapped twice — for the recipient and for the sender — so it
    /// stays private and sender-anonymous, and both wraps carry the identical rumor.
    /// - Parameters:
    ///   - reaction: The reaction content. NIP-25 uses "+" for a like, "-" for a dislike, or an
    ///     emoji such as "🤙".
    ///   - messageID: The rumor id of the message being reacted to (the reaction's "e" tag).
    ///   - author: The reacted-to message's author public key (the reaction's "p" tag).
    ///   - recipientPublicKey: Who receives the reaction gift wrap (typically the message author).
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    /// - Returns: The shared rumor and both gift wraps.
    public func createReactionWithSelfCopy(
        reaction: String = "+",
        to messageID: EventID,
        author: PublicKey,
        recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> SendDirectMessageResult {
        let senderPublicKey = try await signer.publicKey
        let rumor = try makeReactionRumor(
            senderPublicKey: senderPublicKey, reaction: reaction, messageID: messageID, author: author)
        return try await wrapWithSelfCopy(
            rumor: rumor, senderPublicKey: senderPublicKey, to: recipientPublicKey, expiration: expiration)
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
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    /// - Returns: The shared rumor and both gift wraps.
    public func createFileMessageWithSelfCopy(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int? = nil,
        dimensions: String? = nil,
        blurhash: String? = nil,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> SendDirectMessageResult {
        let senderPublicKey = try await signer.publicKey
        let rumor = try makeFileRumor(
            senderPublicKey: senderPublicKey, url: url, mimeType: mimeType, encryption: encryption,
            recipientPublicKey: recipientPublicKey, size: size, dimensions: dimensions, blurhash: blurhash)
        return try await wrapWithSelfCopy(
            rumor: rumor, senderPublicKey: senderPublicKey, to: recipientPublicKey, expiration: expiration)
    }

    /// Creates gift-wrapped events for a group message (sends to multiple recipients)
    /// Each recipient gets their own gift-wrapped copy
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPublicKeys: The recipients' public keys
    ///   - subject: Optional conversation subject
    /// - Returns: Array of gift-wrapped events, one for each recipient plus the sender's copy
    public func createGroupMessage(
        content: String,
        to recipientPublicKeys: [PublicKey],
        subject: String? = nil
    ) async throws -> [Event] {
        // Build tags with all recipients
        var tags: [Tag] = recipientPublicKeys.map { Tag.publicKey($0) }

        if let subject = subject {
            tags.append(.subject(subject))
        }

        let senderPublicKey = try await signer.publicKey
        let rumor = try makeRumor(senderPublicKey: senderPublicKey, content: content, tags: tags)

        // One wrap per recipient, plus a copy for the sender. Each is an independent seal — a
        // relay round-trip apiece for a remote signer — so they run concurrently and are put back
        // in `recipientPublicKeys` order, which callers index into.
        let addressees = recipientPublicKeys + [senderPublicKey]
        return try await withThrowingTaskGroup(of: (offset: Int, wrap: Event).self) { group in
            for (offset, addressee) in addressees.enumerated() {
                group.addTask {
                    (offset, try await GiftWrap.wrap(event: rumor, signer: signer, recipientPublicKey: addressee))
                }
            }
            var wraps: [(offset: Int, wrap: Event)] = []
            wraps.reserveCapacity(addressees.count)
            for try await wrap in group {
                wraps.append(wrap)
            }
            return wraps.sorted { $0.offset < $1.offset }.map(\.wrap)
        }
    }

    // MARK: - Private Helpers

    /// Wraps a shared rumor twice — once for the recipient and once for the sender's self-copy —
    /// and packages both with the rumor.
    ///
    /// NIP-17 delivers every message to both parties so the sender's other devices can reconstruct
    /// the conversation; both wraps carry the identical rumor, whose `id` keys the two copies
    /// together. Any NIP-40 `expiration` is applied to both wraps so the copies expire in lockstep.
    ///
    /// The two wraps are independent seals, so they are built concurrently — with a remote signer
    /// that halves the round-trips a send costs. Internal so
    /// ``NostrMessagesAPI/sendGiftWrapped(_:to:expiration:strategy:)`` can wrap a caller-built rumor.
    func wrapWithSelfCopy(
        rumor: Event,
        senderPublicKey: PublicKey,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?
    ) async throws -> SendDirectMessageResult {
        async let recipientGiftWrap = GiftWrap.wrap(
            event: rumor,
            signer: signer,
            recipientPublicKey: recipientPublicKey,
            expiration: expiration
        )
        async let selfGiftWrap = GiftWrap.wrap(
            event: rumor,
            signer: signer,
            recipientPublicKey: senderPublicKey,
            expiration: expiration
        )

        return SendDirectMessageResult(
            rumor: rumor,
            recipientGiftWrap: try await recipientGiftWrap,
            selfGiftWrap: try await selfGiftWrap
        )
    }

    /// Builds the NIP-17 tag list for a 1-to-1 direct message
    private func directMessageTags(
        recipientPublicKey: PublicKey,
        subject: String?,
        replyTo: EventID?
    ) -> [Tag] {
        var tags: [Tag] = [
            .publicKey(recipientPublicKey)
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
    private func makeRumor(senderPublicKey: PublicKey, content: String, tags: [Tag]) throws -> Event {
        let unsigned = UnsignedEvent(
            publicKey: senderPublicKey,
            kind: .privateDirectMessage,
            tags: tags,
            content: content
        )
        return try unsigned.asRumor()
    }

    /// Creates the unsigned kind-7 reaction rumor. Like the message rumor it is never signed.
    private func makeReactionRumor(
        senderPublicKey: PublicKey, reaction: String, messageID: EventID, author: PublicKey
    ) throws -> Event {
        let tags: [Tag] = [
            .event(messageID),
            .publicKey(author),
            .kind(.privateDirectMessage),
        ]
        let unsigned = UnsignedEvent(
            publicKey: senderPublicKey,
            kind: .reaction,
            tags: tags,
            content: reaction
        )
        return try unsigned.asRumor()
    }

    /// Creates the unsigned kind-15 file-message rumor. Like the message rumor it is never signed.
    /// The content is the file URL; the key, nonce, and hashes are carried as tags.
    private func makeFileRumor(
        senderPublicKey: PublicKey,
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        recipientPublicKey: PublicKey,
        size: Int?,
        dimensions: String?,
        blurhash: String?
    ) throws -> Event {
        var tags: [Tag] = [
            .publicKey(recipientPublicKey),
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
            publicKey: senderPublicKey,
            kind: .fileMessage,
            tags: tags,
            content: url
        )
        return try unsigned.asRumor()
    }
}
