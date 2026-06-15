import Crypto
import Foundation
import NostrCore
import P256K

/// Handles signing and verification of Nostr events
public struct EventSigner: Sendable {
    let keyPair: KeyPair

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
        keyPair.npub
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

    /// Builds an unsigned event for this signer's public key and signs it.
    ///
    /// The convenience signers below differ only in their `kind`, `tags`, and
    /// `content`; this overload keeps the shared `UnsignedEvent` construction in
    /// one place.
    private func sign(kind: Event.Kind, tags: [Tag] = [], content: String = "") throws -> Event {
        try sign(UnsignedEvent(pubkey: publicKey, kind: kind, tags: tags, content: content))
    }

    /// Builds an unsigned event from raw NIP-01 tag arrays and signs it.
    ///
    /// Used by signers whose tags are produced as wire-form arrays (e.g. relay
    /// lists) rather than ``Tag`` values.
    private func sign(kind: Event.Kind, rawTags: [[String]], content: String = "") throws -> Event {
        try sign(UnsignedEvent(pubkey: publicKey, kind: kind, rawTags: rawTags, content: content))
    }

    /// Creates and signs a text note (kind 1)
    public func signTextNote(content: String, tags: [Tag] = []) throws -> Event {
        try sign(kind: .textNote, tags: tags, content: content)
    }

    /// Creates and signs a metadata event (kind 0)
    public func signMetadata(_ metadata: UserMetadata) throws -> Event {
        let content = try JSONEncoder().encode(metadata)
        return try sign(kind: .setMetadata, content: String(data: content, encoding: .utf8) ?? "")
    }

    /// Creates and signs a reaction event (kind 7)
    public func signReaction(to event: Event, content: String = "+") throws -> Event {
        try sign(kind: .reaction, tags: [.event(event.id), .pubkey(event.pubkey)], content: content)
    }

    /// Creates and signs a repost event (kind 6)
    public func signRepost(of event: Event, relayUrl: String? = nil) throws -> Event {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eventJson = try encoder.encode(event)

        return try sign(
            kind: .repost,
            tags: [.event(event.id, relayURL: relayUrl), .pubkey(event.pubkey)],
            content: String(data: eventJson, encoding: .utf8) ?? ""
        )
    }

    /// Creates and signs a delete event (kind 5)
    public func signDeletion(eventIds: [String], reason: String = "") throws -> Event {
        try sign(kind: .eventDeletion, tags: eventIds.map { Tag.event($0) }, content: reason)
    }

    /// Creates and signs a contact list event (kind 3, NIP-02)
    public func signContactList(_ contacts: [Contact]) throws -> Event {
        let tags = contacts.map { Tag.pubkey($0.pubkey, relayURL: $0.relayUrl, petname: $0.petname) }
        return try sign(kind: .contacts, tags: tags, content: "")
    }

    /// Creates and signs a contact list event from pubkeys
    public func signContactList(pubkeys: [String]) throws -> Event {
        let contacts = pubkeys.map { Contact(pubkey: $0) }
        return try signContactList(contacts)
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
        try sign(
            kind: .clientAuthentication,
            tags: [.relay(relayURL.absoluteString), .challenge(challenge)],
            content: ""
        )
    }

    /// Creates and signs a relay list metadata event (kind 10002, NIP-65)
    public func signRelayListMetadata(_ relayList: RelayListMetadata) throws -> Event {
        try sign(kind: .relayListMetadata, rawTags: relayList.toTags(), content: "")
    }

    /// Creates and signs a relay list metadata event from explicit read/write relay URLs (NIP-65).
    /// URLs present in both lists are marked as read+write.
    public func signRelayListMetadata(read: [String] = [], write: [String] = []) throws -> Event {
        let both = Set(read).intersection(write)
        var entries: [RelayListEntry] = []
        for url in read where !both.contains(url) {
            entries.append(RelayListEntry(url: url, usage: .read))
        }
        for url in write where !both.contains(url) {
            entries.append(RelayListEntry(url: url, usage: .write))
        }
        for url in both {
            entries.append(RelayListEntry(url: url, usage: .readWrite))
        }
        return try signRelayListMetadata(RelayListMetadata(entries: entries))
    }

    /// Creates and signs a DM relay list event (kind 10050, NIP-17).
    ///
    /// The event advertises the relays on which the signer wants to receive
    /// private direct messages. Its content is empty; the relays are carried as
    /// `relay` tags.
    public func signDirectMessageRelayList(_ relayList: DirectMessageRelayList) throws -> Event {
        try sign(kind: .directMessageRelayList, rawTags: relayList.toTags(), content: "")
    }

    /// Creates and signs a DM relay list event from relay URLs (kind 10050, NIP-17).
    public func signDirectMessageRelayList(relays: [String]) throws -> Event {
        try signDirectMessageRelayList(DirectMessageRelayList(relays: relays))
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

        return try sign(kind: .zapRequest, tags: tags, content: comment)
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
