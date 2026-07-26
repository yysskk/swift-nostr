import Crypto
import Foundation
import P256K

/// Handles signing and verification of Nostr events
public struct EventSigner: Sendable {
    /// The signer's key pair. `private`: nothing outside this type reads the private key —
    /// callers that need one go through ``NostrSigning``, whose signing and NIP-44 requirements
    /// this type satisfies with the key it holds.
    private let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    public init(privateKeyHex: String) throws {
        self.keyPair = try KeyPair(privateKeyHex: privateKeyHex)
    }

    public init(nsec: String) throws {
        self.keyPair = try KeyPair(nsec: nsec)
    }

    /// The public key associated with this signer
    public var publicKey: String {
        keyPair.publicKeyHex
    }

    /// The public key as npub
    public var npub: String {
        get throws {
            try keyPair.npub
        }
    }

    /// Signs an unsigned event and returns a complete signed event
    public func sign(_ unsignedEvent: UnsignedEvent) throws -> Event {
        // Serialize the event for hashing
        let serialized = try unsignedEvent.serializedForHashing()

        // Calculate the event ID (SHA256 hash of serialized event)
        let hash = SHA256.hash(data: serialized)
        let eventId = Data(hash).hexEncodedString()

        // Sign the hash with the private key using Schnorr
        let privateKey = try P256K.Schnorr.PrivateKey(dataRepresentation: keyPair.privateKey)
        let signature = try privateKey.signature(for: hash)
        let sig = Data(signature.dataRepresentation).hexEncodedString()

        return Event(
            id: eventId,
            pubkey: unsignedEvent.pubkey,
            createdAt: unsignedEvent.createdAt,
            kind: unsignedEvent.kind,
            tags: unsignedEvent.tags,
            content: unsignedEvent.content,
            sig: sig
        )
    }

    /// Encrypts `plaintext` to `recipientPubkey` with NIP-44 v2, as this signer's identity.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPubkey: The recipient's public key (hex).
    /// - Returns: The base64-encoded NIP-44 payload.
    public func nip44Encrypt(_ plaintext: String, to recipientPubkey: String) throws -> String {
        try SealedMessage.seal(plaintext, for: recipientPubkey, using: keyPair).payload
    }

    /// Decrypts a NIP-44 v2 payload from `senderPubkey` addressed to this signer's identity.
    /// - Parameters:
    ///   - ciphertext: The base64-encoded NIP-44 payload.
    ///   - senderPubkey: The sender's public key (hex).
    /// - Returns: The decrypted plaintext.
    public func nip44Decrypt(_ ciphertext: String, from senderPubkey: String) throws -> String {
        try SealedMessage(payload: ciphertext).open(from: senderPubkey, using: keyPair)
    }

    /// Creates and signs a text note (kind 1)
    public func signTextNote(content: String, tags: [Tag] = []) throws -> Event {
        try sign(.textNote(pubkey: publicKey, content: content, tags: tags))
    }

    /// Creates and signs a reaction event (kind 7)
    public func signReaction(to event: Event, content: String = "+") throws -> Event {
        try sign(.reaction(pubkey: publicKey, to: event, content: content))
    }

    /// Creates and signs a repost event (kind 6)
    /// - Parameters:
    ///   - event: The event being reposted; it is embedded in the content and referenced by an `e` tag.
    ///   - relayURL: The relay where the reposted event can be found, recorded in the `e` tag.
    public func signRepost(of event: Event, relayURL: String? = nil) throws -> Event {
        try sign(.repost(pubkey: publicKey, of: event, relayURL: relayURL))
    }

    /// Creates and signs a delete event (kind 5)
    public func signDeletion(eventIds: [String], reason: String = "") throws -> Event {
        try sign(.deletion(pubkey: publicKey, eventIds: eventIds, reason: reason))
    }

    /// Creates and signs a client authentication event (kind 22242, NIP-42)
    /// answering a relay's AUTH challenge.
    ///
    /// The event carries the relay URL and the challenge as tags and an empty
    /// content. It is ephemeral: relays validate it during the AUTH handshake
    /// and neither store nor broadcast it.
    /// https://github.com/nostr-protocol/nips/blob/master/42.md
    ///
    /// - Parameters:
    ///   - relayURL: The URL of the relay being authenticated to, as used to connect.
    ///   - challenge: The challenge string received in the relay's AUTH message.
    public func signClientAuthentication(relayURL: URL, challenge: String) throws -> Event {
        try sign(.clientAuthentication(pubkey: publicKey, relayURL: relayURL, challenge: challenge))
    }

    /// Creates and signs a zap request event (kind 9734, NIP-57).
    ///
    /// A zap request is **not** published to relays — it is sent to the recipient's LNURL-pay
    /// callback (see ``LNURLPayResponse/invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``),
    /// which returns a Lightning invoice and later publishes the matching kind-9735 zap receipt.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - recipientPubkey: The hex-encoded pubkey being zapped (the `p` tag, required).
    ///   - relays: Relays the recipient's wallet should publish the zap receipt to (the `relays`
    ///     tag, required — must contain at least one relay).
    ///   - amountMillisats: The amount in millisatoshis (the `amount` tag). Recommended.
    ///   - lnurl: The recipient's lnurl-pay URL, bech32-encoded with the `lnurl` prefix. Recommended.
    ///   - eventId: The hex event id when zapping an event rather than a person (the `e` tag).
    ///   - eventCoordinate: An event coordinate when zapping an addressable event (the `a` tag).
    ///   - comment: An optional message sent with the payment (the event content).
    public func signZapRequest(
        recipientPubkey: String,
        relays: [String],
        amountMillisats: Int64? = nil,
        lnurl: String? = nil,
        eventId: String? = nil,
        eventCoordinate: String? = nil,
        comment: String = ""
    ) throws -> Event {
        // NIP-57 requires at least one relay so the recipient's wallet knows where to publish the
        // kind-9735 zap receipt; an empty list would otherwise yield a useless ["relays"] tag.
        guard !relays.isEmpty else {
            throw NostrError.invalidData
        }

        var tags: [Tag] = [
            Tag(name: "relays", values: relays),
            .pubkey(recipientPubkey),
        ]
        if let amountMillisats {
            tags.append(Tag(name: "amount", values: [String(amountMillisats)]))
        }
        if let lnurl {
            tags.append(Tag(name: "lnurl", values: [lnurl]))
        }
        if let eventId {
            tags.append(.event(eventId))
        }
        if let eventCoordinate {
            tags.append(Tag(name: "a", values: [eventCoordinate]))
        }

        return try sign(UnsignedEvent(pubkey: publicKey, kind: .zapRequest, tags: tags, content: comment))
    }
}

// MARK: - Proof of Work
extension EventSigner {
    /// Mines `unsignedEvent` to the given NIP-13 difficulty (leading zero bits), then signs it.
    ///
    /// Mining is cooperative and cancellable — see ``ProofOfWork/mine(event:difficulty:)``.
    /// https://github.com/nostr-protocol/nips/blob/master/13.md
    /// - Parameters:
    ///   - unsignedEvent: The event to mine and sign. Any existing `nonce` tags are replaced.
    ///   - difficulty: The target number of leading zero bits, in `0...256`.
    /// - Throws: `CancellationError` if cancelled; ``NostrError/invalidData`` if `difficulty` is
    ///   outside `0...256`.
    public func sign(_ unsignedEvent: UnsignedEvent, proofOfWork difficulty: Int) async throws -> Event {
        let mined = try await ProofOfWork.mine(event: unsignedEvent, difficulty: difficulty)
        return try sign(mined)
    }
}

// MARK: - Event Verification
extension Event {
    /// Verifies the event's signature
    public func verify() throws -> Bool {
        // Reconstruct the unsigned event
        let unsigned = UnsignedEvent(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            rawTags: tags,
            content: content
        )

        // Serialize and hash
        let serialized = try unsigned.serializedForHashing()
        let hash = SHA256.hash(data: serialized)
        let calculatedId = Data(hash).hexEncodedString()

        // Verify the event ID
        guard calculatedId == id else {
            throw NostrError.invalidEventId
        }

        // Verify the signature
        guard let pubkeyData = Data(hexString: pubkey),
            let sigData = Data(hexString: sig)
        else {
            throw NostrError.invalidHex
        }

        let xonlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: pubkeyData, keyParity: 0)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: sigData)

        return xonlyKey.isValidSignature(signature, for: hash)
    }
}
