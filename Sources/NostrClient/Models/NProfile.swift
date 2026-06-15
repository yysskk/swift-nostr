import Foundation
import NostrCore

/// A NIP-19 `nprofile` entity: a public key with optional relay hints.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NProfile: Sendable, Hashable {
    /// The referenced public key (32-byte lowercase hex).
    public let publicKey: String

    /// Relay hints where the profile may be found.
    public let relays: [String]

    /// Creates a profile reference. Throws if `publicKey` is not 32-byte hex.
    public init(publicKey: String, relays: [String] = []) throws {
        self.publicKey = try TLV.normalizedHex32(publicKey)
        self.relays = try TLV.validatedRelays(relays)
    }

    /// Decodes an `nprofile` bech32 string.
    public init(bech32String: String) throws {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "nprofile"))
    }

    init(tlvData: Data) throws {
        var publicKey: String?
        var relays: [String] = []
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                guard record.value.count == 32 else {
                    throw NostrError.invalidNIP19Entity
                }
                publicKey = record.value.hexEncodedString()
            case TLV.Kind.relay.rawValue:
                relays.append(String(decoding: record.value, as: UTF8.self))
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
        TLV.bech32([TLV.specialRecord(hex: publicKey)] + TLV.relayRecords(relays), prefix: "nprofile")
    }
}
