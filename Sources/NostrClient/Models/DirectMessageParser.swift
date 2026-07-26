import Foundation
import NostrCore

/// Parser for received NIP-17 direct messages and NIP-25 reactions to them.
///
/// Takes any ``NostrSigning`` — a local key or a remote NIP-46 signer — because opening
/// a gift wrap needs only NIP-44 decryption, which is part of that abstraction.
public struct DirectMessageParser: Sendable {
    private let signer: any NostrSigning

    public init(signer: any NostrSigning) {
        self.signer = signer
    }

    /// Parses a gift-wrapped event into a DirectMessage.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed DirectMessage
    /// - Throws: ``NostrError/invalidData`` if the inner rumor is not a kind-14 message.
    public func parse(_ giftWrap: Event) async throws -> DirectMessage {
        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
        guard unwrapped.event.kind == .privateDirectMessage else {
            throw NostrError.invalidData
        }
        return try await makeMessage(from: unwrapped, giftWrap: giftWrap)
    }

    /// Parses a gift-wrapped event into a DirectMessageReaction.
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed reaction
    /// - Throws: ``NostrError/invalidData`` if the inner rumor is not a kind-7 reaction or
    ///   does not reference a message.
    public func parseReaction(_ giftWrap: Event) async throws -> DirectMessageReaction {
        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
        guard unwrapped.event.kind == .reaction else {
            throw NostrError.invalidData
        }
        return try makeReaction(from: unwrapped, giftWrap: giftWrap)
    }

    /// Parses a gift-wrapped event into a DirectMessageFile (NIP-17 kind 15).
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The parsed file message
    /// - Throws: ``NostrError/invalidData`` if the inner rumor is not a kind-15 file message or
    ///   is missing a valid decryption key/nonce.
    public func parseFileMessage(_ giftWrap: Event) async throws -> DirectMessageFile {
        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
        guard unwrapped.event.kind == .fileMessage else {
            throw NostrError.invalidData
        }
        return try await makeFile(from: unwrapped, giftWrap: giftWrap)
    }

    /// Unwraps a gift wrap and classifies it as a message (kind 14), reaction (kind 7), or file
    /// message (kind 15).
    /// - Parameter giftWrap: The gift-wrapped event
    /// - Returns: The decrypted payload
    /// - Throws: ``NostrError/invalidData`` for any other inner kind.
    public func parsePayload(_ giftWrap: Event) async throws -> DirectMessagePayload {
        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
        switch unwrapped.event.kind {
        case .privateDirectMessage:
            return .message(try await makeMessage(from: unwrapped, giftWrap: giftWrap))
        case .reaction:
            return .reaction(try makeReaction(from: unwrapped, giftWrap: giftWrap))
        case .fileMessage:
            return .file(try await makeFile(from: unwrapped, giftWrap: giftWrap))
        default:
            throw NostrError.invalidData
        }
    }

    // MARK: - Private builders

    private func makeMessage(
        from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event
    ) async throws -> DirectMessage {
        let rumor = unwrapped.event

        let recipientPubkey = try await addressee(of: rumor)
        let subject = rumor.firstTagValue(named: "subject")

        // A reply is an "e" tag carrying the NIP-10 "reply" marker at its marker position
        // (["e", id, relay, "reply"]); its primary value is the referenced event id.
        let replyTo = rumor.tags(named: "e")
            .first { $0.values.count >= 3 && $0.values[2] == Tag.EventMarker.reply.rawValue }?
            .primaryValue

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
            let messageId = rumor.firstTagValue(named: "e"),
            let author = rumor.firstTagValue(named: "p")
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

    private func makeFile(
        from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event
    ) async throws -> DirectMessageFile {
        let rumor = unwrapped.event

        // A file message must carry a non-empty URL plus a decodable AES-256 key (32 bytes) and
        // GCM nonce (12 bytes); reject malformed events here rather than failing later at decrypt.
        guard
            !rumor.content.isEmpty,
            let keyBase64 = rumor.firstTagValue(named: "decryption-key"),
            let key = Data(base64Encoded: keyBase64),
            key.count == 32,
            let nonceBase64 = rumor.firstTagValue(named: "decryption-nonce"),
            let nonce = Data(base64Encoded: nonceBase64),
            nonce.count == 12
        else {
            throw NostrError.invalidData
        }

        let recipientPubkey = try await addressee(of: rumor)

        return DirectMessageFile(
            rumorId: rumor.id,
            senderPubkey: unwrapped.senderPubkey,
            recipientPubkey: recipientPubkey,
            url: rumor.content,
            mimeType: rumor.firstTagValue(named: "file-type"),
            decryptionKey: key,
            decryptionNonce: nonce,
            encryptedSHA256: rumor.firstTagValue(named: "x"),
            originalSHA256: rumor.firstTagValue(named: "ox"),
            size: rumor.firstTagValue(named: "size").flatMap(Int.init),
            dimensions: rumor.firstTagValue(named: "dim"),
            blurhash: rumor.firstTagValue(named: "blurhash"),
            createdAt: Date(timeIntervalSince1970: TimeInterval(rumor.createdAt)),
            expiresAt: giftWrap.expiration
        )
    }

    /// The rumor's addressee: its "p" tag, or this signer's own key when the tag is absent.
    ///
    /// The gift wrap only reached us because it was sealed to us, so our own key is the right
    /// stand-in — and resolving it lazily keeps a remote signer off the wire for the common case.
    private func addressee(of rumor: Event) async throws -> String {
        if let tagged = rumor.firstTagValue(named: "p") {
            return tagged
        }
        return try await signer.publicKey
    }
}
