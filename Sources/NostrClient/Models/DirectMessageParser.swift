import Foundation
import NostrCore

/// Parser for received NIP-17 direct messages and NIP-25 reactions to them.
///
/// Takes any ``NostrSigning`` — a local key or a remote NIP-46 signer — because opening
/// a gift wrap needs only NIP-44 decryption, which is part of that abstraction.
public struct DirectMessageParser: Sendable {
    private let signer: any NostrSigning

    /// Creates a parser that opens gift wraps addressed to `signer`'s identity.
    public init(signer: any NostrSigning) {
        self.signer = signer
    }

    /// Unwraps a gift wrap and classifies it as a message (kind 14), reaction (kind 7), or file
    /// message (kind 15).
    ///
    /// A message's reply marker whose event id is not canonical hex is ignored, leaving
    /// ``DirectMessage/replyTo`` nil.
    /// - Parameter giftWrap: The gift-wrapped event.
    /// - Returns: The decrypted payload.
    /// - Throws: ``DirectMessagePayload/Error/unexpectedKind(_:)`` for any other inner kind, the
    ///   other ``DirectMessagePayload/Error`` cases for a malformed payload, or the errors of
    ///   ``GiftWrap/unwrap(giftWrap:recipient:)``.
    public func open(_ giftWrap: Event) async throws -> DirectMessagePayload {
        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
        switch unwrapped.event.kind {
        case .privateDirectMessage:
            return .message(try await makeMessage(from: unwrapped, giftWrap: giftWrap))
        case .reaction:
            return .reaction(try makeReaction(from: unwrapped, giftWrap: giftWrap))
        case .fileMessage:
            return .file(try await makeFile(from: unwrapped, giftWrap: giftWrap))
        default:
            throw DirectMessagePayload.Error.unexpectedKind(unwrapped.event.kind)
        }
    }

    // MARK: - Stream parsing

    /// Opens `giftWrap` as a message (kind 14) only, returning nil when it is not a readable message
    /// for this signer — including a reaction or file message, which is rejected before it is
    /// parsed.
    ///
    /// Used by ``DirectMessageSequence``, which walks a public relay stream where foreign and
    /// malformed gift wraps are routine. See ``describesUnreadableEvent(_:)`` for what that
    /// covers — everything else propagates.
    func openMessageIfReadable(_ giftWrap: Event) async throws -> DirectMessage? {
        try await skippingUnreadableEvent {
            let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: signer)
            guard unwrapped.event.kind == .privateDirectMessage else {
                throw DirectMessagePayload.Error.unexpectedKind(unwrapped.event.kind)
            }
            return try await makeMessage(from: unwrapped, giftWrap: giftWrap)
        }
    }

    /// Opens `giftWrap` into a payload, returning nil when it is simply not a readable message
    /// for this signer. The streaming counterpart of ``open(_:)``, mirroring
    /// ``openMessageIfReadable(_:)``.
    func openIfReadable(_ giftWrap: Event) async throws -> DirectMessagePayload? {
        try await skippingUnreadableEvent { try await open(giftWrap) }
    }

    /// Runs `parse`, turning "this event is not readable" into nil and letting every other failure
    /// through.
    private func skippingUnreadableEvent<T>(_ parse: () async throws -> T) async throws -> T? {
        do {
            return try await parse()
        } catch  where Self.describesUnreadableEvent(error) {
            return nil
        }
    }

    /// Whether `error` describes the *event* rather than the signer.
    ///
    /// A gift-wrap stream carries everyone's messages, so wraps sealed to someone else and wraps
    /// whose contents are not a valid NIP-17 payload are expected, and skipping them is how the
    /// sequences find the caller's own messages. A signer that timed out, disconnected, or refused
    /// the request never got as far as judging the event — with a remote NIP-46 signer every
    /// decryption is a relay round-trip — so those failures must reach the caller instead of
    /// silently dropping messages that were merely unread. Anything unrecognized is treated as the
    /// latter: skipping is the lossy answer, so it is only given for known-unreadable events.
    private static func describesUnreadableEvent(_ error: any Error) -> Bool {
        // A seal or rumor that is not the JSON this parser expects.
        if error is DecodingError { return true }
        // An id, key, or signature in the event that is not a well-formed value.
        if error is EventID.Error || error is PublicKey.Error || error is Signature.Error { return true }
        // The seal does not verify as the event it claims to be.
        if error is Event.VerificationError { return true }
        // NIP-44 refused the payload — the usual outcome for a wrap sealed to someone else.
        if error is NIP44Payload.Error { return true }
        // The wrap is not a gift wrap or its seal is not a seal, the seal's signature does not
        // verify, the rumor's id is not its hash, or the rumor claims another author.
        if error is GiftWrap.Error { return true }
        // The rumor is not a well-formed message, reaction, or file.
        if error is DirectMessagePayload.Error { return true }
        return false
    }

    // MARK: - Private builders

    private func makeMessage(
        from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event
    ) async throws -> DirectMessage {
        let rumor = unwrapped.event

        let recipientPublicKey = try await addressee(of: rumor)
        let subject = rumor.firstTagValue(named: .subject)

        // A reply is an "e" tag carrying the NIP-10 "reply" marker at its marker position
        // (["e", id, relay, "reply"]); its primary value is the referenced event id.
        let replyTo = rumor.tags(named: .event)
            .first { $0.values.count >= 3 && $0.values[2] == Tag.EventMarker.reply.rawValue }?
            .primaryValue
            .flatMap(EventID.init)

        return DirectMessage(
            rumorID: rumor.id,
            senderPublicKey: unwrapped.senderPublicKey,
            recipientPublicKey: recipientPublicKey,
            content: rumor.content,
            createdAt: rumor.createdAt,
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
        // missing as a parse failure rather than surfacing an empty public key callers can't detect.
        guard
            let messageID = rumor.firstTagValue(named: .event).flatMap(EventID.init),
            let author = rumor.firstTagValue(named: .publicKey).flatMap(PublicKey.init)
        else {
            throw DirectMessagePayload.Error.missingReactionTarget
        }

        return DirectMessageReaction(
            rumorID: rumor.id,
            senderPublicKey: unwrapped.senderPublicKey,
            messageID: messageID,
            messageAuthorPublicKey: author,
            content: rumor.content,
            createdAt: rumor.createdAt,
            expiresAt: giftWrap.expiration
        )
    }

    private func makeFile(
        from unwrapped: GiftWrap.UnwrappedMessage, giftWrap: Event
    ) async throws -> DirectMessageFile {
        let rumor = unwrapped.event

        // A file message must carry an http(s) URL plus a decodable AES-256 key (32 bytes) and GCM
        // nonce (12 bytes); reject malformed events here rather than failing later at download or
        // decrypt.
        guard let url = URL(string: rumor.content), url.isWebURL else {
            throw DirectMessagePayload.Error.invalidFileURL
        }
        guard
            let key = rumor.firstTagValue(named: "decryption-key").flatMap({ Data(base64Encoded: $0) }),
            key.count == 32
        else {
            throw DirectMessagePayload.Error.invalidDecryptionKey
        }
        guard
            let nonce = rumor.firstTagValue(named: "decryption-nonce").flatMap({ Data(base64Encoded: $0) }),
            nonce.count == 12
        else {
            throw DirectMessagePayload.Error.invalidDecryptionNonce
        }

        let recipientPublicKey = try await addressee(of: rumor)

        let attachment = FileAttachment(
            url: url,
            mimeType: rumor.firstTagValue(named: "file-type"),
            decryptionKey: key,
            decryptionNonce: nonce,
            encryptedSHA256: rumor.firstTagValue(named: "x"),
            originalSHA256: rumor.firstTagValue(named: "ox"),
            size: rumor.firstTagValue(named: "size").flatMap(Int.init),
            dimensions: rumor.firstTagValue(named: "dim"),
            blurhash: rumor.firstTagValue(named: "blurhash")
        )

        return DirectMessageFile(
            rumorID: rumor.id,
            senderPublicKey: unwrapped.senderPublicKey,
            recipientPublicKey: recipientPublicKey,
            attachment: attachment,
            createdAt: rumor.createdAt,
            expiresAt: giftWrap.expiration
        )
    }

    /// The rumor's addressee: its "p" tag, or this signer's own key when the tag is absent.
    ///
    /// The gift wrap only reached us because it was sealed to us, so our own key is the right
    /// stand-in — and resolving it lazily keeps a remote signer off the wire for the common case.
    /// A `p` tag that is not a canonical hex key names no one, so the rumor is rejected as
    /// ``DirectMessagePayload/Error/invalidRecipient`` rather than attributed to the wrong
    /// conversation.
    private func addressee(of rumor: Event) async throws -> PublicKey {
        if let tagged = rumor.firstTagValue(named: .publicKey) {
            guard let publicKey = PublicKey(tagged) else { throw DirectMessagePayload.Error.invalidRecipient }
            return publicKey
        }
        return try await signer.publicKey
    }
}
