import Foundation
import NostrCore

// MARK: - Profiles and Contacts
extension EventTemplate {
    /// A metadata event (kind 0) whose content is `metadata` encoded as JSON.
    /// https://github.com/nostr-protocol/nips/blob/master/01.md
    /// - Parameter metadata: The profile to publish.
    /// - Returns: The template for the metadata event.
    /// - Throws: `EncodingError` if `metadata` cannot be encoded as JSON.
    public static func metadata(_ metadata: UserMetadata) throws -> EventTemplate {
        let content = try JSONEncoder().encode(metadata)
        return EventTemplate(kind: .metadata, content: String(decoding: content, as: UTF8.self))
    }

    /// A follow list (kind 3): one `p` tag per contact, carrying its relay URL and petname, and
    /// an empty content.
    /// https://github.com/nostr-protocol/nips/blob/master/02.md
    /// - Parameter contacts: The followed public keys, in order.
    /// - Returns: The template for the follow list.
    public static func followList(_ contacts: [Contact]) -> EventTemplate {
        EventTemplate(
            kind: .followList,
            tags: contacts.map { .publicKey($0.publicKey, relayURL: $0.relayURL, petname: $0.petname) }
        )
    }
}
