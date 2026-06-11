import Foundation

/// Builder for creating NIP-17 direct message events
public struct DirectMessageBuilder: Sendable {
    private let senderKeyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.senderKeyPair = keyPair
    }

    /// Creates a gift-wrapped direct message event ready for publishing.
    ///
    /// This only produces the recipient's wrap; NIP-17 also requires a self-copy
    /// for sent history and multi-device sync, so prefer
    /// ``createMessageWithSelfCopy(content:to:subject:replyTo:)``.
    /// - Parameters:
    ///   - content: The message content
    ///   - recipientPubkey: The recipient's public key (hex)
    ///   - subject: Optional conversation subject
    ///   - replyTo: Optional event ID to reply to
    /// - Returns: A gift-wrapped event for the recipient
    @available(
        *, deprecated, renamed: "createMessageWithSelfCopy",
        message: "NIP-17 requires a self-copy; use createMessageWithSelfCopy instead."
    )
    public func createMessage(
        content: String,
        to recipientPubkey: String,
        subject: String? = nil,
        replyTo: String? = nil
    ) throws -> Event {
        let rumor = try makeRumor(
            content: content,
            tags: directMessageTags(recipientPubkey: recipientPubkey, subject: subject, replyTo: replyTo)
        )

        return try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: recipientPubkey
        )
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
    /// - Returns: The shared rumor and both gift wraps
    public func createMessageWithSelfCopy(
        content: String,
        to recipientPubkey: String,
        subject: String? = nil,
        replyTo: String? = nil
    ) throws -> SendDirectMessageResult {
        let rumor = try makeRumor(
            content: content,
            tags: directMessageTags(recipientPubkey: recipientPubkey, subject: subject, replyTo: replyTo)
        )

        let recipientGiftWrap = try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: recipientPubkey
        )
        let selfGiftWrap = try GiftWrap.wrap(
            event: rumor,
            senderKeyPair: senderKeyPair,
            recipientPubkey: senderKeyPair.publicKeyHex
        )

        return SendDirectMessageResult(
            rumor: rumor,
            recipientGiftWrap: recipientGiftWrap,
            selfGiftWrap: selfGiftWrap
        )
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
        var tags: [[String]] = recipientPubkeys.map { ["p", $0] }

        if let subject = subject {
            tags.append(["subject", subject])
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

    /// Builds the NIP-17 tag list for a 1-to-1 direct message
    private func directMessageTags(
        recipientPubkey: String,
        subject: String?,
        replyTo: String?
    ) -> [[String]] {
        var tags: [[String]] = [
            ["p", recipientPubkey]
        ]

        if let subject = subject {
            tags.append(["subject", subject])
        }

        if let replyTo = replyTo {
            tags.append(["e", replyTo, "", "reply"])
        }

        return tags
    }

    /// Creates the unsigned kind-14 rumor with its id computed.
    /// The rumor is deliberately never signed (NIP-17: a leaked signed rumor would
    /// be cryptographic proof of authorship and destroy deniability).
    private func makeRumor(content: String, tags: [[String]]) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: senderKeyPair.publicKeyHex,
            kind: .privateDirectMessage,
            tags: tags,
            content: content
        )
        return try unsigned.asRumor()
    }
}
