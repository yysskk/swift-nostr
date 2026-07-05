import Foundation
import NostrCore

/// A NIP-51 set: an addressable (30000-series) categorized list identified by a `d` tag,
/// with optional presentation metadata and NIP-44-self-encrypted private items.
///
/// Sets group items under a user-chosen category (the `d` identifier), such as a named
/// bookmark folder or follow group. Public items are the event's non-metadata tags; private
/// items are a NIP-44-self-encrypted JSON tag array in the content, readable only by the
/// author. Sets are addressable, so publishing replaces the previous set with the same kind
/// and `d` identifier — start from the fetched current set when editing to avoid dropping items.
/// https://github.com/nostr-protocol/nips/blob/master/51.md
public struct NostrListSet: Sendable, Hashable {
    /// The set's event kind (e.g. ``Event/Kind/bookmarkSet``, ``Event/Kind/followSet``).
    public let kind: Event.Kind

    /// The `d` tag value identifying the set within its kind for the author.
    public let identifier: String

    /// An optional human-readable title (`title` tag).
    public var title: String?

    /// An optional cover image URL (`image` tag).
    public var imageURL: String?

    /// An optional description (`description` tag).
    public var description: String?

    /// Publicly visible items, stored as the event's non-metadata tags.
    public var publicItems: [Tag]

    /// Private items, self-encrypted (NIP-44) into the event content and readable only
    /// by the author.
    public var privateItems: [Tag]

    /// Creates a set.
    /// - Throws: ``NostrError/invalidData`` when `kind` is not addressable (30000..<40000)
    ///   or `identifier` is empty.
    public init(
        kind: Event.Kind,
        identifier: String,
        title: String? = nil,
        imageURL: String? = nil,
        description: String? = nil,
        publicItems: [Tag] = [],
        privateItems: [Tag] = []
    ) throws {
        guard kind.isAddressable, !identifier.isEmpty else {
            throw NostrError.invalidData
        }
        self.kind = kind
        self.identifier = identifier
        self.title = title
        self.imageURL = imageURL
        self.description = description
        self.publicItems = publicItems
        self.privateItems = privateItems
    }

    /// Reads the public face of a set event: its metadata tags plus every non-metadata public
    /// item. Private items stay empty (decrypting them needs the author's key — see
    /// ``EventSigner/openSet(_:)``).
    /// - Throws: ``NostrError/invalidData`` when the event has no `d` identifier tag.
    public init(event: Event) throws {
        let tags = event.structuredTags
        guard let identifier = tags.first(where: { $0.name == "d" })?.primaryValue else {
            throw NostrError.invalidData
        }
        self.kind = event.kind
        self.identifier = identifier
        self.title = tags.first { $0.name == "title" }?.primaryValue
        self.imageURL = tags.first { $0.name == "image" }?.primaryValue
        self.description = tags.first { $0.name == "description" }?.primaryValue
        // Everything except the metadata tags is a public item, preserving unmodeled tags.
        let metadata: Set<String> = ["d", "title", "image", "description"]
        self.publicItems = tags.filter { !metadata.contains($0.name) }
        self.privateItems = []
    }

    /// The `kind:pubkey:identifier` coordinate used in `a`-tag references to this set.
    public func coordinate(author: String) -> String {
        "\(kind.rawValue):\(author):\(identifier)"
    }

    /// A NIP-19 `naddr` addressing this set for `author`.
    public func naddr(author: String, relays: [String] = []) throws -> NAddr {
        try NAddr(identifier: identifier, author: author, kind: kind.rawValue, relays: relays)
    }
}
