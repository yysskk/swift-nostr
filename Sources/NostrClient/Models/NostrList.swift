import Foundation
import NostrCore

/// A NIP-51 standard list (mute 10000, pin 10001, bookmarks 10003).
///
/// Public items are the event's tags; private items are a NIP-44-self-encrypted JSON tag
/// array in the content, readable only by the author. Lists are replaceable — publishing
/// replaces the previous list of the same kind, so start from the fetched current list
/// when editing to avoid dropping items.
/// https://github.com/nostr-protocol/nips/blob/master/51.md
public struct NostrList: Sendable, Hashable {
    /// The list's event kind (e.g. ``Event/Kind/muteList``, ``Event/Kind/pinList``,
    /// ``Event/Kind/bookmarkList``).
    public let kind: Event.Kind

    /// Publicly visible items, stored as the event's tags.
    public var publicItems: [Tag]

    /// Private items, self-encrypted (NIP-44) into the event content and readable only
    /// by the author.
    public var privateItems: [Tag]

    /// Creates a list with explicit public and private items.
    public init(kind: Event.Kind, publicItems: [Tag] = [], privateItems: [Tag] = []) {
        self.kind = kind
        self.publicItems = publicItems
        self.privateItems = privateItems
    }

    /// Reads the public items of a list event; private items stay empty (decrypting them
    /// needs the author's key — see ``EventSigner/openList(_:)``).
    public init(event: Event) {
        self.kind = event.kind
        self.publicItems = event.structuredTags
        self.privateItems = []
    }
}

/// The plaintext form of a NIP-51 list's private items: a JSON tag array, self-encrypted with
/// NIP-44 into the event content.
///
/// Only the encoding lives here; the sealing itself goes through the signer, synchronously for a
/// local key and over a relay round-trip for a remote one. The private items of both the standard
/// lists and the 30000-series sets share this representation, so this helper is deliberately kept
/// independent of ``NostrList``.
enum ListItemCipher {
    /// The JSON to seal for `items`, or nil when there is nothing to seal.
    ///
    /// NIP-44 sealing enforces a minimum plaintext size, so an empty item set is represented by
    /// empty event content rather than an encrypted empty array.
    static func plaintext(_ items: [Tag]) throws -> String? {
        guard !items.isEmpty else { return nil }
        let data = try JSONSerialization.data(
            withJSONObject: items.map(\.rawArray),
            options: [.withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    /// The tags encoded in an opened payload.
    static func items(fromJSON json: String) throws -> [Tag] {
        guard let rawArrays = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String]] else {
            throw NostrError.decryptionFailed
        }
        return rawArrays.compactMap(Tag.init(rawArray:))
    }
}
