import Foundation
import NostrCore

extension NIP19Entity {
    /// Decodes a NIP-21 `nostr:` URI, e.g. `nostr:npub1...`.
    ///
    /// The scheme is matched case-insensitively and a `nostr://` form some clients
    /// emit is tolerated. `nsec` is rejected — private keys must never travel in URIs
    /// (NIP-21 allows only npub, nprofile, note, nevent, naddr).
    /// https://github.com/nostr-protocol/nips/blob/master/21.md
    public init(nostrURI: String) throws {
        let trimmed = nostrURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("nostr:") else {
            throw NostrError.invalidNostrURI
        }
        var remainder = String(trimmed.dropFirst("nostr:".count))
        if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst("//".count))
        }
        let entity = try NIP19Entity.decode(remainder)
        if case .nsec = entity {
            throw NostrError.invalidNostrURI
        }
        self = entity
    }

    /// The canonical NIP-21 `nostr:` URI for this entity (no `//`).
    /// - Throws: ``NostrError/invalidNostrURI`` for `nsec`.
    public var nostrURI: String {
        get throws {
            if case .nsec = self {
                throw NostrError.invalidNostrURI
            }
            return try "nostr:" + encoded
        }
    }
}
