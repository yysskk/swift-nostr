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
    /// needs the author's key — see ``init(event:decryptingWith:)``).
    public init(event: Event) {
        self.kind = event.kind
        self.publicItems = event.tags
        self.privateItems = []
    }

    /// Reads a list event authored by `signer`, decrypting its private items.
    ///
    /// Works with any signer, local or remote; empty content means there are no private items.
    /// - Parameters:
    ///   - event: The list event.
    ///   - signer: The author's signer, which encrypted the private items to itself.
    /// - Throws: ``NostrList/Error/malformedPrivateItems`` if the decrypted content is not a JSON
    ///   tag array; anything resolving the signer's public key or decrypting throws — for example
    ///   when the content was not encrypted by `signer` to itself.
    public init(event: Event, decryptingWith signer: some NostrSigning) async throws {
        self.init(event: event)
        guard let items = try await ListItemCipher.open(event.content, with: signer) else {
            throw Error.malformedPrivateItems
        }
        privateItems = items
    }

    /// An error reading a NIP-51 list.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The decrypted content is not a JSON array of tags.
        case malformedPrivateItems

        public var errorDescription: String? {
            switch self {
            case .malformedPrivateItems:
                return "A NIP-51 list's private items must be a JSON tag array"
            }
        }
    }
}

/// The private items of a NIP-51 list or set: a JSON tag array, NIP-44-encrypted to the author's
/// own key in the event content.
///
/// The encryption goes through the signer, synchronously for a local key and over a relay
/// round-trip for a remote one. The standard lists and the 30000-series sets share this
/// representation, so this helper is deliberately kept independent of ``NostrList``.
enum ListItemCipher {
    /// Encrypts `items` to `signer`'s own public key, or returns empty content when there are none.
    static func seal(_ items: [Tag], with signer: some NostrSigning) async throws -> String {
        guard let json = try plaintext(items) else { return "" }
        return try await signer.nip44Encrypt(json, to: signer.publicKey)
    }

    /// Decrypts content `signer` encrypted to itself into items (empty content → []), or nil when
    /// the decrypted content is not a JSON tag array.
    static func open(_ content: String, with signer: some NostrSigning) async throws -> [Tag]? {
        guard !content.isEmpty else { return [] }
        return try items(fromJSON: await signer.nip44Decrypt(content, from: signer.publicKey))
    }

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

    /// The tags encoded in an opened payload, or nil when it is not a JSON tag array.
    static func items(fromJSON json: String) -> [Tag]? {
        guard let rawArrays = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String]] else {
            return nil
        }
        return rawArrays.map(Tag.init(rawArray:))
    }
}
