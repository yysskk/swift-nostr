import Foundation
import NostrCore

/// Contact information for NIP-02 Contact List
/// https://github.com/nostr-protocol/nips/blob/master/02.md
public struct Contact: Codable, Hashable, Sendable {
    /// The public key of the contact
    public let pubkey: PublicKey

    /// The main relay URL where the client reads events from this contact
    public let relayURL: RelayURL?

    /// A local name (petname) for this contact
    public let petname: String?

    /// Creates a contact.
    /// - Parameters:
    ///   - pubkey: The contact's public key.
    ///   - relayURL: The main relay URL where the client reads events from this contact.
    ///   - petname: A local name for this contact.
    public init(pubkey: PublicKey, relayURL: RelayURL? = nil, petname: String? = nil) {
        self.pubkey = pubkey
        self.relayURL = relayURL
        self.petname = petname
    }

    /// Converts to a tag array for NIP-02 event
    public func toTag() -> [String] {
        var tag = ["p", pubkey.hex]
        if let relayURL = relayURL {
            tag.append(relayURL.description)
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
    ///
    /// Returns nil unless the tag is a `p` tag whose value is a canonical hex public key. The
    /// relay hint is the list author's own content, so one that is not a valid relay URL is read
    /// as absent rather than failing the contact.
    public static func fromTag(_ tag: [String]) -> Contact? {
        guard tag.count >= 2, tag[0] == "p", let pubkey = PublicKey(tag[1]) else {
            return nil
        }

        let relayURL = tag.count > 2 ? RelayURL(tag[2]) : nil
        let petname = tag.count > 3 && !tag[3].isEmpty ? tag[3] : nil

        return Contact(pubkey: pubkey, relayURL: relayURL, petname: petname)
    }
}

// MARK: - Contact List Helpers
extension Event {
    /// Extracts contacts from a kind 3 (contacts) event
    /// Returns nil if the event is not a contact list event. A `p` tag whose value is not a
    /// canonical hex public key is skipped.
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
