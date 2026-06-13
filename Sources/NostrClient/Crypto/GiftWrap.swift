import Foundation

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
        public let senderPubkey: String
        /// The original unwrapped event (rumor)
        public let event: Event
    }

    /// Creates a gift-wrapped event
    /// - Parameters:
    ///   - event: The event to wrap (will be converted to rumor if signed)
    ///   - senderKeyPair: The sender's keypair
    ///   - recipientPubkey: The recipient's public key (hex)
    ///   - expiration: Optional NIP-40 expiration. Applied to the outer gift wrap (the stored
    ///     kind-1059 event relays act on) so the message disappears after the given time. The
    ///     inner rumor is unaffected, keeping the plaintext content private until then.
    /// - Returns: The gift-wrapped event ready for publishing
    public static func wrap(
        event: Event,
        senderKeyPair: KeyPair,
        recipientPubkey: String,
        expiration: Date? = nil
    ) throws -> Event {
        // 1. Create rumor (unsigned event JSON)
        let rumor = createRumor(from: event)
        let rumorJson = try encodeRumor(rumor)

        // 2. Create seal (encrypt rumor to recipient)
        let sealedRumor = try SealedMessage.seal(rumorJson, for: recipientPubkey, using: senderKeyPair)

        let sealUnsigned = UnsignedEvent(
            pubkey: senderKeyPair.publicKeyHex,
            createdAt: randomizedTimestamp(),
            kind: .seal,
            tags: [],
            content: sealedRumor.payload
        )

        let sealSigner = EventSigner(keyPair: senderKeyPair)
        let seal = try sealSigner.sign(sealUnsigned)
        let sealJson = try encodeSeal(seal)

        // 3. Create gift wrap (encrypt seal with ephemeral key)
        let ephemeralKeyPair = try KeyPair()
        let sealedMessage = try SealedMessage.seal(sealJson, for: recipientPubkey, using: ephemeralKeyPair)

        var wrapTags: [Tag] = [.pubkey(recipientPubkey)]
        if let expiration {
            wrapTags.append(.expiration(expiration))
        }

        let wrapUnsigned = UnsignedEvent(
            pubkey: ephemeralKeyPair.publicKeyHex,
            createdAt: randomizedTimestamp(),
            kind: .giftWrap,
            tags: wrapTags,
            content: sealedMessage.payload
        )

        let wrapSigner = EventSigner(keyPair: ephemeralKeyPair)
        return try wrapSigner.sign(wrapUnsigned)
    }

    /// Unwraps a gift-wrapped event
    /// - Parameters:
    ///   - giftWrap: The gift-wrapped event
    ///   - recipientKeyPair: The recipient's keypair
    /// - Returns: The unwrapped message containing sender and original event
    public static func unwrap(
        giftWrap: Event,
        recipientKeyPair: KeyPair
    ) throws -> UnwrappedMessage {
        guard giftWrap.kind == .giftWrap else {
            throw NostrError.invalidData
        }

        // 1. Open gift wrap to get seal
        let sealJson = try SealedMessage(payload: giftWrap.content).open(from: giftWrap.pubkey, using: recipientKeyPair)
        let seal = try decodeSeal(sealJson)

        guard seal.kind == .seal else {
            throw NostrError.invalidData
        }

        // Verify seal signature
        guard try seal.verify() else {
            throw NostrError.verificationFailed
        }

        // 2. Open seal to get rumor
        let rumorJson = try SealedMessage(payload: seal.content).open(from: seal.pubkey, using: recipientKeyPair)
        let rumor = try decodeRumor(rumorJson)

        // 3. Return the unwrapped message
        return UnwrappedMessage(
            senderPubkey: seal.pubkey,
            event: rumor
        )
    }

    // MARK: - Private Helpers

    /// Creates a rumor from an event (removing signature)
    private static func createRumor(from event: Event) -> Rumor {
        Rumor(
            id: event.id,
            pubkey: event.pubkey,
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

    /// Decodes a rumor from JSON string
    private static func decodeRumor(_ json: String) throws -> Event {
        let decoder = JSONDecoder()
        let rumor = try decoder.decode(Rumor.self, from: Data(json.utf8))
        // Convert rumor back to Event (with empty signature since it's a rumor)
        return Event(
            id: rumor.id,
            pubkey: rumor.pubkey,
            createdAt: rumor.createdAt,
            kind: rumor.kind,
            tags: rumor.tags,
            content: rumor.content,
            sig: ""
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
    private static func randomizedTimestamp() -> Int64 {
        let now = Int64(Date().timeIntervalSince1970)
        let twoDays: Int64 = 2 * 24 * 60 * 60
        let randomOffset = Int64.random(in: -twoDays...0)
        return now + randomOffset
    }
}

/// Internal representation of a rumor (unsigned event)
private struct Rumor: Codable {
    let id: String
    let pubkey: String
    let createdAt: Int64
    let kind: Event.Kind
    let tags: [[String]]
    let content: String

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
    }
}
