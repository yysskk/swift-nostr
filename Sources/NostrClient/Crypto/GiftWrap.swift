import Foundation
import NostrCore

/// NIP-59 Gift Wrap
/// https://github.com/nostr-protocol/nips/blob/master/59.md
///
/// Gift wrapping provides sender anonymity by wrapping events in multiple layers:
/// 1. Rumor: The original unsigned event
/// 2. Seal: Rumor encrypted to recipient, signed by sender
/// 3. Gift Wrap: Seal encrypted to recipient, signed by ephemeral key
public struct GiftWrap: Sendable {

    /// Unwrapped gift wrap result containing the sender and the original event
    public struct UnwrappedMessage: Sendable {
        /// The actual sender's public key (from the seal)
        public let senderPublicKey: PublicKey
        /// The original unwrapped event (rumor)
        public let event: Event
    }

    /// Authors `template` as an unsigned rumor under `signer`'s public key and gift-wraps it for
    /// `recipientPublicKey`.
    ///
    /// Everything the sender's identity is needed for — authoring the rumor, sealing it, and signing
    /// the seal — goes through ``NostrSigning``, so a remote NIP-46 signer wraps as well as a local
    /// key does, and the rumor's author always matches the seal that ``unwrap(giftWrap:recipient:)``
    /// checks it against. The outer wrap key is ephemeral by design and is generated here.
    ///
    /// The rumor's id is the hash of the template's contents under the signer's key, so wrapping the
    /// same template twice — once per addressee — yields the same rumor id in two distinct wraps.
    /// - Parameters:
    ///   - template: The rumor's kind, tags, content, and creation time. The rumor is never signed.
    ///   - signer: The sender's signer, local or remote.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - expiration: Optional NIP-40 expiration. Applied to the outer gift wrap (the stored
    ///     kind-1059 event relays act on) so the message disappears after the given time. The
    ///     inner rumor is unaffected, keeping the plaintext content private until then.
    /// - Returns: The gift-wrapped event ready for publishing.
    /// - Throws: Anything `signer` throws while resolving its public key, encrypting, or signing.
    public static func wrap(
        _ template: EventTemplate,
        signer: any NostrSigning,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> Event {
        let rumor = UnsignedEvent(template, publicKey: try await signer.publicKey).asRumor()
        return try await wrap(rumor: rumor, signer: signer, to: recipientPublicKey, expiration: expiration)
    }

    /// Gift-wraps an already-built `rumor` for `recipientPublicKey`.
    ///
    /// Internal so callers that wrap one rumor for several addressees share it — and its id —
    /// without resolving the signer's public key per wrap. The seal is authored under
    /// `rumor.publicKey`, which must be `signer`'s key: a local signer refuses to sign another key's
    /// seal.
    static func wrap(
        rumor: Event,
        signer: any NostrSigning,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?
    ) async throws -> Event {
        let rumorJSON = try encodeRumor(rumor)

        // Seal: the rumor encrypted to the recipient and signed by the sender.
        let sealUnsigned = UnsignedEvent(
            publicKey: rumor.publicKey,
            createdAt: randomizedTimestamp(),
            kind: .seal,
            tags: [],
            content: try await signer.nip44Encrypt(rumorJSON, to: recipientPublicKey)
        )

        let seal = try await signer.sign(sealUnsigned)
        let sealJSON = try encodeSeal(seal)

        // Gift wrap: the seal encrypted with an ephemeral key, which hides the sender.
        let ephemeralSigner = EventSigner(keyPair: KeyPair())

        var wrapTags: [Tag] = [.publicKey(recipientPublicKey)]
        if let expiration {
            wrapTags.append(.expiration(expiration))
        }

        let wrapUnsigned = UnsignedEvent(
            publicKey: ephemeralSigner.publicKey,
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: wrapTags,
            content: try ephemeralSigner.nip44Encrypt(sealJSON, to: recipientPublicKey)
        )

        return try ephemeralSigner.sign(wrapUnsigned)
    }

    /// Unwraps a gift-wrapped event, authenticating the sender.
    ///
    /// The seal's signature is verified, and the rumor it carries must name that same sealer as its
    /// author and carry the true hash of its own contents. So both
    /// ``UnwrappedMessage/senderPublicKey`` and the returned event's `publicKey` are attested by the
    /// seal's signature, and the event's `id` can be trusted as an identity for the message.
    /// - Parameters:
    ///   - giftWrap: The gift-wrapped event
    ///   - recipient: The recipient's signer, local or remote
    /// - Returns: The unwrapped message containing sender and original event
    /// - Throws: ``GiftWrap/Error/unexpectedKind(_:)`` if the wrap is not kind 1059 or its seal is
    ///   not kind 13, ``GiftWrap/Error/invalidSealSignature`` if the seal's signature does not
    ///   verify, ``Event/VerificationError`` if the seal's id does not match its contents or it is
    ///   unsigned, ``GiftWrap/Error/invalidRumorID`` if the rumor's id is not the hash of its
    ///   contents, ``GiftWrap/Error/authorMismatch`` if the rumor claims a different author than
    ///   the seal, a `DecodingError` if a layer is not an event, or what `recipient` throws when a
    ///   NIP-44 layer does not decrypt (``NIP44Payload/Error`` for a local signer).
    public static func unwrap(
        giftWrap: Event,
        recipient: any NostrSigning
    ) async throws -> UnwrappedMessage {
        guard giftWrap.kind == .giftWrap else {
            throw Error.unexpectedKind(giftWrap.kind)
        }

        // 1. Open gift wrap to get seal
        let sealJSON = try await recipient.nip44Decrypt(giftWrap.content, from: giftWrap.publicKey)
        let seal = try decodeSeal(sealJSON)

        guard seal.kind == .seal else {
            throw Error.unexpectedKind(seal.kind)
        }

        // Verify seal signature
        do {
            try seal.verify()
        } catch .invalidSignature {
            throw Error.invalidSealSignature
        }

        // 2. Open seal to get rumor
        let rumorJSON = try await recipient.nip44Decrypt(seal.content, from: seal.publicKey)
        let rumor = try decodeRumor(rumorJSON)

        // NIP-17: "Clients MUST verify if pubkey of the kind:13 is the same pubkey on the kind:14,
        // otherwise any sender can impersonate others by simply changing the pubkey on kind:14."
        // The seal's signature proves only who sealed it; the rumor inside is unsigned by design,
        // so without this the author it names is whatever the sealer chose to write.
        guard rumor.publicKey == seal.publicKey else {
            throw Error.authorMismatch
        }

        // 3. Return the unwrapped message
        return UnwrappedMessage(
            senderPublicKey: seal.publicKey,
            event: rumor
        )
    }

    // MARK: - Private Helpers

    /// Encodes a rumor to JSON string, without a signature field.
    private static func encodeRumor(_ event: Event) throws -> String {
        let rumor = Rumor(
            id: event.id,
            publicKey: event.publicKey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )
        let data = try JSONEncoder().encode(rumor)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a rumor from JSON string, checking that its id is the hash of its own contents.
    ///
    /// A rumor carries no signature, so its id is not attested by anything — but callers use it as
    /// the message's identity: `DirectMessage.rumorID` keys storage and correlates reactions. Left
    /// unchecked, a sender could choose an id that collides with a message from another
    /// conversation and overwrite it.
    private static func decodeRumor(_ json: String) throws -> Event {
        let decoder = JSONDecoder()
        let rumor = try decoder.decode(Rumor.self, from: Data(json.utf8))

        // Rebuilt through `UnsignedEvent` so the id comes from the same canonical NIP-01
        // serialization that signing and rumor construction use, rather than a second copy of it.
        let unsigned = UnsignedEvent(
            publicKey: rumor.publicKey,
            createdAt: rumor.createdAt,
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content
        )

        guard rumor.id == unsigned.computedID else {
            throw Error.invalidRumorID
        }

        // Convert rumor back to Event (without a signature since it's a rumor)
        return Event(
            id: rumor.id,
            publicKey: rumor.publicKey,
            createdAt: rumor.createdAt,
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content,
            signature: nil
        )
    }

    /// Encodes a seal to JSON string
    private static func encodeSeal(_ seal: Event) throws -> String {
        let data = try JSONEncoder().encode(seal)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes a seal from JSON string
    private static func decodeSeal(_ json: String) throws -> Event {
        let decoder = JSONDecoder()
        return try decoder.decode(Event.self, from: Data(json.utf8))
    }

    /// Returns a randomized timestamp in the past (up to 2 days ago) for privacy.
    /// Only past offset is used so relays that reject "created_at too late" will accept the event.
    private static func randomizedTimestamp() -> Timestamp {
        let window: Duration = .seconds(2 * 24 * 60 * 60)
        let offset = Int64.random(in: 0...window.components.seconds)
        return Timestamp.now.advanced(by: .seconds(-offset))
    }

    /// An error unwrapping a NIP-59 gift wrap.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// A layer is not the kind it must be: the wrap kind 1059, or the seal inside it kind 13
        /// (payload: the kind found).
        case unexpectedKind(Event.Kind)
        /// The seal's signature does not verify against its author.
        case invalidSealSignature
        /// The rumor names a different author than the seal that carries it, which would let a
        /// sender impersonate someone else.
        case authorMismatch
        /// The rumor's id is not the hash of its contents.
        case invalidRumorID

        public var errorDescription: String? {
            switch self {
            case .unexpectedKind(let kind):
                return "Unexpected kind \(kind.rawValue) in a gift wrap"
            case .invalidSealSignature:
                return "The gift wrap's seal signature does not verify"
            case .authorMismatch:
                return "The gift wrap's rumor names a different author than its seal"
            case .invalidRumorID:
                return "The gift wrap's rumor id does not match its contents"
            }
        }
    }
}

/// Internal representation of a rumor (unsigned event)
private struct Rumor: Codable {
    let id: EventID
    let publicKey: PublicKey
    let createdAt: Timestamp
    let kind: Event.Kind
    let tags: [Tag]
    let content: String

    enum CodingKeys: String, CodingKey {
        case id
        case publicKey = "pubkey"
        case createdAt = "created_at"
        case kind
        case tags
        case content
    }
}
