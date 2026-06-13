import Foundation

/// Parser for received NIP-17 direct messages and NIP-25 reactions to them.
public struct DirectMessageParser: Sendable {
    private let recipientKeyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.recipientKeyPair = keyPair
    }

    /// Parses a gift-wrapped event into a DirectMessage.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed DirectMessage
    /// - Throws: ``NostrError/invalidData`` if the inner rumor is not a kind-14 message.
    public func parse(_ giftWrap: Event) throws -> DirectMessage {
        let unwrapped = try GiftWrap.unwrap(giftWrap: giftWrap, recipientKeyPair: recipientKeyPair)
        guard unwrapped.event.kind == .privateDirectMessage else {
            throw NostrError.invalidData
        }
        return makeMessage(from: unwrapped, giftWrap: giftWrap)
    }

    /// Parses a gift-wrapped event into a DirectMessageReaction.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed reaction
    /// - Throws: ``NostrError/invalidData`` if the inner rumor is not a kind-7 reaction or
    ///   does not reference a message.
    public func parseReaction(_ giftWrap: Event) throws -> DirectMessageReaction {
        let unwrapped = try GiftWrap.unwrap(giftWrap: giftWrap, recipientKeyPair: recipientKeyPair)
        guard unwrapped.event.kind == .reaction else {
            throw NostrError.invalidData
        }
        return try makeReaction(from: unwrapped, giftWrap: giftWrap)
    }

    /// Unwraps a gift wrap and classifies it as a message (kind 14) or a reaction (kind 7).
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The decrypted payload
    /// - Throws: ``NostrError/invalidData`` for any other inner kind.
    public func parsePayload(_ giftWrap: Event) throws -> DirectMessagePayload {
        let unwrapped = try GiftWrap.unwrap(giftWrap: giftWrap, recipientKeyPair: recipientKeyPair)
        switch unwrapped.event.kind {
        case .privateDirectMessage:
            return .message(makeMessage(from: unwrapped, giftWrap: giftWrap))
        case .reaction:
            return .reaction(try makeReaction(from: unwrapped, giftWrap: giftWrap))
        default:
            throw NostrError.invalidData
        }
    }

    // MARK: - Private builders

    private func makeMessage(from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event) -> DirectMessage {
        let rumor = unwrapped.event

        // Extract recipient from p tag
        let recipientPubkey =
            rumor.tags
            .first { $0.first == "p" && $0.count >= 2 }
            .map { $0[1] } ?? recipientKeyPair.publicKeyHex

        // Extract optional subject
        let subject = rumor.tags
            .first { $0.first == "subject" && $0.count >= 2 }
            .map { $0[1] }

        // Extract optional reply reference
        let replyTo = rumor.tags
            .first { $0.first == "e" && $0.count >= 4 && $0[3] == "reply" }
            .map { $0[1] }

        return DirectMessage(
            rumorId: rumor.id,
            senderPubkey: unwrapped.senderPubkey,
            recipientPubkey: recipientPubkey,
            content: rumor.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(rumor.createdAt)),
            subject: subject,
            replyTo: replyTo,
            // NIP-40 expiration lives on the public gift wrap, not the encrypted rumor.
            expiresAt: giftWrap.expiration
        )
    }

    private func makeReaction(
        from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event
    ) throws -> DirectMessageReaction {
        let rumor = unwrapped.event

        // A reaction must reference both the message ("e") and its author ("p"). Treat either
        // missing as a parse failure rather than surfacing an empty pubkey callers can't detect.
        guard
            let messageId = rumor.tags
                .first(where: { $0.first == "e" && $0.count >= 2 })
                .map({ $0[1] }),
            let author = rumor.tags
                .first(where: { $0.first == "p" && $0.count >= 2 })
                .map({ $0[1] })
        else {
            throw NostrError.invalidData
        }

        return DirectMessageReaction(
            rumorId: rumor.id,
            senderPubkey: unwrapped.senderPubkey,
            messageId: messageId,
            messageAuthorPubkey: author,
            content: rumor.content,
            createdAt: Date(timeIntervalSince1970: TimeInterval(rumor.createdAt)),
            expiresAt: giftWrap.expiration
        )
    }
}
