import Foundation
import NostrCore

/// A NIP-19 `nprofile` entity: a public key with optional relay hints.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NProfile: Sendable, Hashable {
    /// The referenced public key.
    public let publicKey: PublicKey

    /// Relay hints where the profile may be found. Decoding skips a hint that is not a valid
    /// relay URL; encoding writes each hint in canonical form.
    public let relays: [RelayURL]

    /// Creates a profile reference.
    /// - Throws: ``NostrError/invalidTLV`` if a relay hint's canonical form is longer than 255 bytes.
    public init(publicKey: PublicKey, relays: [RelayURL] = []) throws {
        self.publicKey = publicKey
        self.relays = try TLV.validatedRelays(relays)
    }

    /// Decodes an `nprofile` bech32 string.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if the payload has no public key or one that is
    ///   not 32 bytes, besides the bech32 and TLV errors.
    public init(bech32String: String) throws {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "nprofile"))
    }

    init(tlvData: Data) throws {
        var publicKey: PublicKey?
        var relays: [RelayURL] = []
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                publicKey = try TLV.publicKey(record)
            case TLV.Kind.relay.rawValue:
                if let relay = TLV.relay(record) {
                    relays.append(relay)
                }
            default:
                continue
            }
        }
        guard let publicKey else {
            throw NostrError.invalidNIP19Entity
        }
        self.publicKey = publicKey
        self.relays = relays
    }

    /// The canonical `nprofile` bech32 string.
    public var encoded: String {
        get throws {
            try TLV.bech32([TLV.specialRecord(publicKey)] + TLV.relayRecords(relays), prefix: "nprofile")
        }
    }
}
