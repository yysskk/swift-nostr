import Foundation
import NostrCore

/// Contact information for NIP-02 Contact List
/// https://github.com/nostr-protocol/nips/blob/master/02.md
public struct Contact: Codable, Hashable, Sendable {
    /// The public key of the contact (hex-encoded)
    public let pubkey: String

    /// The main relay URL where the client reads events from this contact
    public let relayURL: String?

    /// A local name (petname) for this contact
    public let petname: String?

    /// Creates a contact from a hex-encoded public key.
    /// - Parameters:
    ///   - pubkey: The contact's hex-encoded public key.
    ///   - relayURL: The main relay URL where the client reads events from this contact.
    ///   - petname: A local name for this contact.
    public init(pubkey: String, relayURL: String? = nil, petname: String? = nil) {
        self.pubkey = pubkey
        self.relayURL = relayURL
        self.petname = petname
    }

    /// Creates a Contact from an npub
    /// - Parameters:
    ///   - npub: The contact's public key in bech32 `npub` form (NIP-19).
    ///   - relayURL: The main relay URL where the client reads events from this contact.
    ///   - petname: A local name for this contact.
    /// - Throws: ``NostrError`` if `npub` is not a valid npub string.
    public init(npub: String, relayURL: String? = nil, petname: String? = nil) throws {
        let publicKey = try PublicKey(npub: npub)
        self.pubkey = publicKey.hex
        self.relayURL = relayURL
        self.petname = petname
    }

    /// Converts to a tag array for NIP-02 event
    public func toTag() -> [String] {
        var tag = ["p", pubkey]
        if let relayURL = relayURL {
            tag.append(relayURL)
            if let petname = petname {
                tag.append(petname)
            }
        } else if let petname = petname {
            tag.append("")
            tag.append(petname)
        }
        return tag
    }

    /// Creates a Contact from a "p" tag array
    public static func fromTag(_ tag: [String]) -> Contact? {
        guard tag.count >= 2, tag[0] == "p" else {
            return nil
        }

        let pubkey = tag[1]
        let relayURL = tag.count > 2 && !tag[2].isEmpty ? tag[2] : nil
        let petname = tag.count > 3 && !tag[3].isEmpty ? tag[3] : nil

        return Contact(pubkey: pubkey, relayURL: relayURL, petname: petname)
    }
}

// MARK: - Contact List Helpers
extension Event {
    /// Extracts contacts from a kind 3 (contacts) event
    /// Returns nil if the event is not a contact list event
    public var contacts: [Contact]? {
        guard kind == .contacts else {
            return nil
        }

        return tags.compactMap { Contact.fromTag($0) }
    }

    /// Checks if this is a contact list event
    public var isContactList: Bool {
        kind == .contacts
    }
}
