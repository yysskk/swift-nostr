import Crypto
import Foundation
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

    /// Creates and signs a text note (kind 1)
    public func signTextNote(content: String, tags: [[String]] = []) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .textNote,
            tags: tags,
            content: content
        )
        return try sign(unsigned)
    }

    /// Creates and signs a metadata event (kind 0)
    public func signMetadata(_ metadata: UserMetadata) throws -> Event {
        let content = try JSONEncoder().encode(metadata)
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .setMetadata,
            content: String(data: content, encoding: .utf8) ?? ""
        )
        return try sign(unsigned)
    }

    /// Creates and signs a reaction event (kind 7)
    public func signReaction(to event: Event, content: String = "+") throws -> Event {
        let tags: [[String]] = [
            ["e", event.id],
            ["p", event.pubkey],
        ]
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .reaction,
            tags: tags,
            content: content
        )
        return try sign(unsigned)
    }

    /// Creates and signs a repost event (kind 6)
    public func signRepost(of event: Event, relayUrl: String? = nil) throws -> Event {
        var tags: [[String]] = [
            ["e", event.id],
            ["p", event.pubkey],
        ]
        if let relayUrl = relayUrl {
            tags[0].append(relayUrl)
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eventJson = try encoder.encode(event)

        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .repost,
            tags: tags,
            content: String(data: eventJson, encoding: .utf8) ?? ""
        )
        return try sign(unsigned)
    }

    /// Creates and signs a delete event (kind 5)
    public func signDeletion(eventIds: [String], reason: String = "") throws -> Event {
        let tags = eventIds.map { ["e", $0] }
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .eventDeletion,
            tags: tags,
            content: reason
        )
        return try sign(unsigned)
    }

    /// Creates and signs a contact list event (kind 3, NIP-02)
    public func signContactList(_ contacts: [Contact]) throws -> Event {
        let tags = contacts.map { $0.toTag() }
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .contacts,
            tags: tags,
            content: ""
        )
        return try sign(unsigned)
    }

    /// Creates and signs a contact list event from pubkeys
    public func signContactList(pubkeys: [String]) throws -> Event {
        let contacts = pubkeys.map { Contact(pubkey: $0) }
        return try signContactList(contacts)
    }

    /// Creates and signs a relay list metadata event (kind 10002, NIP-65)
    public func signRelayListMetadata(_ relayList: RelayListMetadata) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: publicKey,
            kind: .relayListMetadata,
            tags: relayList.toTags(),
            content: ""
        )
        return try sign(unsigned)
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
            tags: tags,
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

// MARK: - User Metadata
/// User profile metadata (NIP-01)
public struct UserMetadata: Codable, Sendable {
    public var name: String?
    public var about: String?
    public var picture: String?
    public var nip05: String?
    public var banner: String?
    public var displayName: String?
    public var website: String?
    public var lud06: String?
    public var lud16: String?

    enum CodingKeys: String, CodingKey {
        case name
        case about
        case picture
        case nip05
        case banner
        case displayName = "display_name"
        case website
        case lud06
        case lud16
    }

    public init(
        name: String? = nil,
        about: String? = nil,
        picture: String? = nil,
        nip05: String? = nil,
        banner: String? = nil,
        displayName: String? = nil,
        website: String? = nil,
        lud06: String? = nil,
        lud16: String? = nil
    ) {
        self.name = name
        self.about = about
        self.picture = picture
        self.nip05 = nip05
        self.banner = banner
        self.displayName = displayName
        self.website = website
        self.lud06 = lud06
        self.lud16 = lud16
    }
}
