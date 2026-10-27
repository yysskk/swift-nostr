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
    /// conversation. Both wraps carry the identical unsigned rumor, built by
    /// ``EventTemplate/directMessage(_:to:subject:replyTo:)``; its `id` is the key for matching the
    /// message when it echoes back from a relay.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPublicKey: The recipient's public key
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional id of the event to reply to
    ///   - expiration: Optional NIP-40 expiration for a disappearing message. Applied to both
    ///     gift wraps so the recipient and self copies expire together.
    /// - Returns: The shared rumor and both gift wraps.
    public func createMessageWithSelfCopy(
        content: String,
        to recipientPublicKey: PublicKey,
        subject: String? = nil,
        replyTo: EventID? = nil,
        expiration: Timestamp? = nil
    ) async throws -> GiftWrappedMessage {
        try await wrapWithSelfCopy(
            .directMessage(content, to: recipientPublicKey, subject: subject, replyTo: replyTo),
            to: recipientPublicKey,
            expiration: expiration
        )
    }

    /// Creates a gift-wrapped NIP-25 reaction to a direct message, plus the sender's self-copy.
    ///
    /// The reaction is an unsigned kind-7 rumor referencing the target message's rumor id and
    /// author, built by ``EventTemplate/directMessageReaction(to:author:content:)``. Like a message
    /// it is wrapped twice — for the recipient and for the sender — so it stays private and
    /// sender-anonymous, and both wraps carry the identical rumor.
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
    ) async throws -> GiftWrappedMessage {
        try await wrapWithSelfCopy(
            .directMessageReaction(to: messageID, author: author, content: reaction),
            to: recipientPublicKey,
            expiration: expiration
        )
    }

    /// Creates a gift-wrapped NIP-17 kind-15 file message, plus the sender's self-copy.
    ///
    /// The file must already be encrypted (see ``EncryptedFile/encrypt(_:)``) and uploaded; describe
    /// it with a ``FileAttachment``. The message carries the URL as its content and the key, nonce,
    /// and hashes as tags — built by ``EventTemplate/fileMessage(_:to:)`` — wrapped exactly like a
    /// text message so it stays private.
    /// - Parameters:
    ///   - attachment: The uploaded encrypted file.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: Optional NIP-40 expiration applied to both gift wraps.
    /// - Returns: The shared rumor and both gift wraps.
    public func createFileMessageWithSelfCopy(
        _ attachment: FileAttachment,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> GiftWrappedMessage {
        try await wrapWithSelfCopy(
            .fileMessage(attachment, to: recipientPublicKey),
            to: recipientPublicKey,
            expiration: expiration
        )
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
        // Never signed, like every NIP-17 rumor.
        let rumor = UnsignedEvent(
            EventTemplate(kind: .privateDirectMessage, tags: tags, content: content), publicKey: senderPublicKey
        ).asRumor()

        // One wrap per recipient, plus a copy for the sender. Each is an independent seal — a
        // relay round-trip apiece for a remote signer — so they run concurrently and are put back
        // in `recipientPublicKeys` order, which callers index into.
        let addressees = recipientPublicKeys + [senderPublicKey]
        return try await withThrowingTaskGroup(of: (offset: Int, wrap: Event).self) { group in
            for (offset, addressee) in addressees.enumerated() {
                group.addTask {
                    (offset, try await GiftWrap.wrap(rumor: rumor, signer: signer, to: addressee, expiration: nil))
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

    /// Authors `template` as a rumor under the signer's public key and wraps it twice — see
    /// ``wrapWithSelfCopy(_:senderPublicKey:to:expiration:)``.
    func wrapWithSelfCopy(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?
    ) async throws -> GiftWrappedMessage {
        try await wrapWithSelfCopy(
            template, senderPublicKey: try await signer.publicKey, to: recipientPublicKey, expiration: expiration)
    }

    /// Authors `template` as a rumor under `senderPublicKey` and wraps it twice — once for the
    /// recipient and once for the sender's self-copy — packaging both with the rumor.
    ///
    /// The rumor is deliberately never signed (NIP-17: a leaked signed rumor would be cryptographic
    /// proof of authorship and destroy deniability). NIP-17 delivers every message to both parties
    /// so the sender's other devices can reconstruct the conversation; both wraps carry the
    /// identical rumor, whose `id` keys the two copies together. Any NIP-40 `expiration` is applied
    /// to both wraps so the copies expire in lockstep.
    ///
    /// The two wraps are independent seals, so they are built concurrently — with a remote signer
    /// that halves the round-trips a send costs. Internal so ``NostrMessagesAPI`` can wrap a
    /// caller's template under the public key it already resolved.
    func wrapWithSelfCopy(
        _ template: EventTemplate,
        senderPublicKey: PublicKey,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?
    ) async throws -> GiftWrappedMessage {
        let rumor = UnsignedEvent(template, publicKey: senderPublicKey).asRumor()
        async let recipientGiftWrap = GiftWrap.wrap(
            rumor: rumor, signer: signer, to: recipientPublicKey, expiration: expiration)
        async let selfGiftWrap = GiftWrap.wrap(
            rumor: rumor, signer: signer, to: senderPublicKey, expiration: expiration)

        return GiftWrappedMessage(
            rumor: rumor,
            recipientGiftWrap: try await recipientGiftWrap,
            selfGiftWrap: try await selfGiftWrap
        )
    }
}
