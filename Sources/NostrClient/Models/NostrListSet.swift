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
    /// - Throws: ``NostrListSet/Error/invalidKind(_:)`` when `kind` is not addressable
    ///   (30000..<40000), or ``NostrListSet/Error/missingIdentifier`` when `identifier` is empty.
    public init(
        kind: Event.Kind,
        identifier: String,
        title: String? = nil,
        imageURL: String? = nil,
        description: String? = nil,
        publicItems: [Tag] = [],
        privateItems: [Tag] = []
    ) throws(NostrListSet.Error) {
        guard kind.isAddressable else { throw .invalidKind(kind) }
        guard !identifier.isEmpty else { throw .missingIdentifier }
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
    /// ``init(event:decryptingWith:)``).
    /// - Throws: ``NostrListSet/Error/missingIdentifier`` when the event has no `d` identifier tag.
    public init(event: Event) throws(NostrListSet.Error) {
        let tags = event.tags
        guard let identifier = tags.first(where: { $0.name == .identifier })?.primaryValue else {
            throw .missingIdentifier
        }
        self.kind = event.kind
        self.identifier = identifier
        self.title = tags.first { $0.name == "title" }?.primaryValue
        self.imageURL = tags.first { $0.name == "image" }?.primaryValue
        self.description = tags.first { $0.name == "description" }?.primaryValue
        // Everything except the metadata tags is a public item, preserving unmodeled tags.
        self.publicItems = tags.filter { !Self.reservedTagNames.contains($0.name) }
        self.privateItems = []
    }

    /// Reads a set event authored by `signer`, decrypting its private items.
    ///
    /// Works with any signer, local or remote; empty content means there are no private items.
    /// - Parameters:
    ///   - event: The set event.
    ///   - signer: The author's signer, which encrypted the private items to itself.
    /// - Throws: ``NostrListSet/Error/missingIdentifier`` if the event has no `d` identifier tag;
    ///   ``NostrListSet/Error/malformedPrivateItems`` if the decrypted content is not a JSON tag
    ///   array; anything resolving the signer's public key or decrypting throws — for example when
    ///   the content was not encrypted by `signer` to itself.
    public init(event: Event, decryptingWith signer: some NostrSigning) async throws {
        try self.init(event: event)
        guard let items = try await ListItemCipher.open(event.content, with: signer) else {
            throw Error.malformedPrivateItems
        }
        privateItems = items
    }

    /// Tag names carried by dedicated properties (`d`, `title`, `image`, `description`)
    /// rather than as free-form public items, so they are never emitted twice.
    static let reservedTagNames: Set<Tag.Name> = [.identifier, "title", "image", "description"]

    /// The coordinate used in `a`-tag references to this set for `author`.
    public func coordinate(author: PublicKey) -> EventCoordinate {
        EventCoordinate(kind: kind, publicKey: author, identifier: identifier)
    }

    /// A NIP-19 `naddr` addressing this set for `author`.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes.
    public func naddr(author: PublicKey, relays: [RelayURL] = []) throws(NIP19Entity.Error) -> NAddr {
        try NAddr(identifier: identifier, author: author, kind: kind, relays: relays)
    }

    /// An error reading or building a NIP-51 set.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The kind is not addressable (30000..<40000), so it cannot be a set (payload: the kind).
        case invalidKind(Event.Kind)
        /// The set has no `d` identifier: an empty identifier, or an event without a `d` tag.
        case missingIdentifier
        /// The decrypted content is not a JSON array of tags.
        case malformedPrivateItems

        public var errorDescription: String? {
            switch self {
            case .invalidKind(let kind):
                return "A NIP-51 set must have an addressable kind, got \(kind.rawValue)"
            case .missingIdentifier:
                return "A NIP-51 set must have a d identifier"
            case .malformedPrivateItems:
                return "A NIP-51 set's private items must be a JSON tag array"
            }
        }
    }
}
