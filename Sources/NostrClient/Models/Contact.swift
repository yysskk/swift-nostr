import Foundation
import NostrCore

/// Contact information for NIP-02 Contact List
/// https://github.com/nostr-protocol/nips/blob/master/02.md
public struct Contact: Codable, Hashable, Sendable {
    /// The public key of the contact
    public let publicKey: PublicKey

    /// The main relay URL where the client reads events from this contact
    public let relayURL: RelayURL?

    /// A local name (petname) for this contact
    public let petname: String?

    enum CodingKeys: String, CodingKey {
        case publicKey = "pubkey"
        case relayURL
        case petname
    }

    /// Creates a contact.
    /// - Parameters:
    ///   - publicKey: The contact's public key.
    ///   - relayURL: The main relay URL where the client reads events from this contact.
    ///   - petname: A local name for this contact.
    public init(publicKey: PublicKey, relayURL: RelayURL? = nil, petname: String? = nil) {
        self.publicKey = publicKey
        self.relayURL = relayURL
        self.petname = petname
    }

    /// The `p` tag for a NIP-02 contact list: `["p", public key, relayURL, petname]`, with an empty
    /// relay placeholder when only a petname is set.
    public var tag: Tag {
        .publicKey(publicKey, relayURL: relayURL, petname: petname)
    }

    /// Creates a contact from a "p" tag.
    ///
    /// Returns nil unless the tag is a `p` tag whose value is a canonical hex public key. The
    /// relay hint is the list author's own content, so one that is not a valid relay URL is read
    /// as absent rather than failing the contact.
    public init?(tag: Tag) {
        guard tag.name == .publicKey, let publicKey = tag.primaryValue.flatMap(PublicKey.init) else {
            return nil
        }

        let relayURL = tag.values.count > 1 ? RelayURL(tag.values[1]) : nil
        let petname = tag.values.count > 2 && !tag.values[2].isEmpty ? tag.values[2] : nil

        self.init(publicKey: publicKey, relayURL: relayURL, petname: petname)
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

        return tags.compactMap(Contact.init(tag:))
    }

    /// Checks if this is a contact list event
    public var isContactList: Bool {
        kind == .contacts
    }
}
