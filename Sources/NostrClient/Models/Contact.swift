import Foundation

/// Contact information for NIP-02 Contact List
/// https://github.com/nostr-protocol/nips/blob/master/02.md
public struct Contact: Codable, Hashable, Sendable {
    /// The public key of the contact (hex-encoded)
    public let pubkey: String

    /// The main relay URL where the client reads events from this contact
    public let relayUrl: String?

    /// A local name (petname) for this contact
    public let petname: String?

    public init(pubkey: String, relayUrl: String? = nil, petname: String? = nil) {
        self.pubkey = pubkey
        self.relayUrl = relayUrl
        self.petname = petname
    }

    /// Creates a Contact from an npub
    public init(npub: String, relayUrl: String? = nil, petname: String? = nil) throws {
        let publicKey = try PublicKey(npub: npub)
        self.pubkey = publicKey.hex
        self.relayUrl = relayUrl
        self.petname = petname
    }

    /// Converts to a tag array for NIP-02 event
    public func toTag() -> [String] {
        var tag = ["p", pubkey]
        if let relayUrl = relayUrl {
            tag.append(relayUrl)
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
        let relayUrl = tag.count > 2 && !tag[2].isEmpty ? tag[2] : nil
        let petname = tag.count > 3 && !tag[3].isEmpty ? tag[3] : nil

        return Contact(pubkey: pubkey, relayUrl: relayUrl, petname: petname)
    }
}

// MARK: - Contact List Helpers
extension Event {
    /// Extracts contacts from a kind 3 (contacts) event
    /// Returns nil if the event is not a contact list event
    public var contacts: [Contact]? {
        guard kind == Kind.contacts.rawValue else {
            return nil
        }

        return tags.compactMap { Contact.fromTag($0) }
    }

    /// Checks if this is a contact list event
    public var isContactList: Bool {
        kind == Kind.contacts.rawValue
    }
}
