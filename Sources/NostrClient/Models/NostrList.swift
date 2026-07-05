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

/// Encrypts and decrypts a NIP-51 list's private items as a NIP-44-self-encrypted JSON
/// tag array.
///
/// The private items of both the standard lists and the future 30000-series sets share
/// this representation, so this helper is deliberately kept independent of ``NostrList``.
enum ListItemCipher {
    /// Encrypts tags as a NIP-44-self-encrypted JSON array (empty string when `items` is empty).
    static func encrypt(_ items: [Tag], using keyPair: KeyPair) throws -> String {
        // NIP-44 sealing enforces a minimum plaintext size, so an empty item set is
        // represented by empty content rather than an encrypted empty array.
        guard !items.isEmpty else { return "" }
        let data = try JSONSerialization.data(
            withJSONObject: items.map(\.rawArray),
            options: [.withoutEscapingSlashes]
        )
        let json = String(decoding: data, as: UTF8.self)
        return try SealedMessage.seal(json, for: keyPair.publicKeyHex, using: keyPair).payload
    }

    /// Decrypts a self-encrypted tag-array payload (empty string → []).
    static func decrypt(_ payload: String, using keyPair: KeyPair) throws -> [Tag] {
        guard !payload.isEmpty else { return [] }
        let json = try SealedMessage(payload: payload).open(from: keyPair.publicKeyHex, using: keyPair)
        guard let rawArrays = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String]] else {
            throw NostrError.decryptionFailed
        }
        return rawArrays.compactMap(Tag.init(rawArray:))
    }
}
