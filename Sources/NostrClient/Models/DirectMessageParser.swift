import Foundation

/// Parser for received NIP-17 direct messages
public struct DirectMessageParser: Sendable {
    private let recipientKeyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.recipientKeyPair = keyPair
    }

    /// Parses a gift-wrapped event into a DirectMessage
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed DirectMessage
    public func parse(_ giftWrap: Event) throws -> DirectMessage {
        let unwrapped = try GiftWrap.unwrap(
            giftWrap: giftWrap,
            recipientKeyPair: recipientKeyPair
        )

        let rumor = unwrapped.event

        guard rumor.kind == .privateDirectMessage else {
            throw NostrError.invalidData
        }

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
            replyTo: replyTo
        )
    }
}
