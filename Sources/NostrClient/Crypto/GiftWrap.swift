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

    /// Creates a gift-wrapped event
    ///
    /// Everything the sender's identity is needed for — sealing the rumor and signing the seal —
    /// goes through ``NostrSigning``, so a remote NIP-46 signer wraps as well as a local
    /// key does. The outer wrap key is ephemeral by design and is generated here.
    /// - Parameters:
    ///   - event: The event to wrap (will be converted to rumor if signed)
    ///   - signer: The sender's signer, local or remote
    ///   - recipientPublicKey: The recipient's public key
    ///   - expiration: Optional NIP-40 expiration. Applied to the outer gift wrap (the stored
    ///     kind-1059 event relays act on) so the message disappears after the given time. The
    ///     inner rumor is unaffected, keeping the plaintext content private until then.
    /// - Returns: The gift-wrapped event ready for publishing
    public static func wrap(
        event: Event,
        signer: any NostrSigning,
        recipientPublicKey: PublicKey,
        expiration: Timestamp? = nil
    ) async throws -> Event {
        // 1. Create rumor (unsigned event JSON)
        let rumor = createRumor(from: event)
        let rumorJson = try encodeRumor(rumor)

        // 2. Create seal (encrypt rumor to recipient, signed by the sender)
        let sealUnsigned = UnsignedEvent(
            publicKey: try await signer.publicKey,
            createdAt: randomizedTimestamp(),
            kind: .seal,
            tags: [],
            content: try await signer.nip44Encrypt(rumorJson, to: recipientPublicKey)
        )

        let seal = try await signer.sign(sealUnsigned)
        let sealJson = try encodeSeal(seal)

        // 3. Create gift wrap (encrypt seal with an ephemeral key, which hides the sender)
        let ephemeralSigner = EventSigner(keyPair: try KeyPair())

        var wrapTags: [Tag] = [.publicKey(recipientPublicKey)]
        if let expiration {
            wrapTags.append(.expiration(expiration))
        }

        let wrapUnsigned = UnsignedEvent(
            publicKey: ephemeralSigner.publicKey,
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: wrapTags,
            content: try ephemeralSigner.nip44Encrypt(sealJson, to: recipientPublicKey)
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
    /// - Throws: ``NostrError/invalidData`` if the layers are not the expected kinds,
    ///   ``NostrError/verificationFailed`` if the seal's signature does not verify or the rumor
    ///   claims a different author, ``Event/VerificationError`` if the seal's id does not match its
    ///   contents or it is unsigned, ``NostrError/invalidEventID`` if the rumor's id is not the
    ///   hash of its contents, or what `recipient` throws when a NIP-44 layer does not open
    ///   (``SealedMessage/Error`` for a local signer).
    public static func unwrap(
        giftWrap: Event,
        recipient: any NostrSigning
    ) async throws -> UnwrappedMessage {
        guard giftWrap.kind == .giftWrap else {
            throw NostrError.invalidData
        }

        // 1. Open gift wrap to get seal
        let sealJson = try await recipient.nip44Decrypt(giftWrap.content, from: giftWrap.publicKey)
        let seal = try decodeSeal(sealJson)

        guard seal.kind == .seal else {
            throw NostrError.invalidData
        }

        // Verify seal signature
        guard try seal.verify() else {
            throw NostrError.verificationFailed
        }

        // 2. Open seal to get rumor
        let rumorJson = try await recipient.nip44Decrypt(seal.content, from: seal.publicKey)
        let rumor = try decodeRumor(rumorJson)

        // NIP-17: "Clients MUST verify if pubkey of the kind:13 is the same pubkey on the kind:14,
        // otherwise any sender can impersonate others by simply changing the pubkey on kind:14."
        // The seal's signature proves only who sealed it; the rumor inside is unsigned by design,
        // so without this the author it names is whatever the sealer chose to write.
        guard rumor.publicKey == seal.publicKey else {
            throw NostrError.verificationFailed
        }

        // 3. Return the unwrapped message
        return UnwrappedMessage(
            senderPublicKey: seal.publicKey,
            event: rumor
        )
    }

    // MARK: - Private Helpers

    /// Creates a rumor from an event (removing signature)
    private static func createRumor(from event: Event) -> Rumor {
        Rumor(
            id: event.id,
            publicKey: event.publicKey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )
    }

    /// Encodes a rumor to JSON string
    private static func encodeRumor(_ rumor: Rumor) throws -> String {
        let encoder = JSONEncoder()
        let data = try encoder.encode(rumor)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NostrError.serializationFailed
        }
        return json
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
            rawTags: rumor.tags,
            content: rumor.content
        )

        guard rumor.id == (try unsigned.computedID) else {
            throw NostrError.invalidEventID
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
        let encoder = JSONEncoder()
        let data = try encoder.encode(seal)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NostrError.serializationFailed
        }
        return json
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
}

/// Internal representation of a rumor (unsigned event)
private struct Rumor: Codable {
    let id: EventID
    let publicKey: PublicKey
    let createdAt: Timestamp
    let kind: Event.Kind
    let tags: [[String]]
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
