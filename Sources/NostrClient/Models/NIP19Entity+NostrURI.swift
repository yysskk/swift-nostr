import Foundation
import NostrCore

extension NIP19Entity {
    /// Decodes a NIP-21 `nostr:` URI, e.g. `nostr:npub1...`.
    ///
    /// The scheme is matched case-insensitively and a `nostr://` form some clients
    /// emit is tolerated. `nsec` is rejected — private keys must never travel in URIs
    /// (NIP-21 allows only npub, nprofile, note, nevent, naddr).
    /// https://github.com/nostr-protocol/nips/blob/master/21.md
    /// - Throws: ``NIP19Entity/Error/missingNostrScheme`` if the string does not start with
    ///   `nostr:`, ``NIP19Entity/Error/privateKeyInURI`` if it holds an `nsec`, or the errors of
    ///   ``NIP19Entity/decode(_:)``.
    public init(nostrURI: String) throws(NIP19Entity.Error) {
        let trimmed = nostrURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("nostr:") else {
            throw .missingNostrScheme
        }
        var remainder = String(trimmed.dropFirst("nostr:".count))
        if remainder.hasPrefix("//") {
            remainder = String(remainder.dropFirst("//".count))
        }
        let entity = try NIP19Entity.decode(remainder)
        if case .nsec = entity {
            throw .privateKeyInURI
        }
        self = entity
    }

    /// The canonical NIP-21 `nostr:` URI for this entity (no `//`).
    /// - Throws: ``NIP19Entity/Error/privateKeyInURI`` for `nsec`, or the errors of ``encoded``.
    public var nostrURI: String {
        get throws(NIP19Entity.Error) {
            if case .nsec = self {
                throw .privateKeyInURI
            }
            return try "nostr:" + encoded
        }
    }
}
