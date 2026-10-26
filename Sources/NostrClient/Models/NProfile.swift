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
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes.
    public init(publicKey: PublicKey, relays: [RelayURL] = []) throws(NIP19Entity.Error) {
        self.publicKey = publicKey
        self.relays = try TLV.validatedRelays(relays)
    }

    /// Decodes an `nprofile` bech32 string.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if the string is not valid bech32,
    ///   ``NIP19Entity/Error/unexpectedPrefix(_:)`` if its prefix is not `nprofile`,
    ///   ``NIP19Entity/Error/malformedTLV`` if a record is truncated,
    ///   ``NIP19Entity/Error/missingPublicKey`` if it has no public key, or
    ///   ``NIP19Entity/Error/invalidLength(_:)`` if the public key is not 32 bytes.
    public init(bech32String: String) throws(NIP19Entity.Error) {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "nprofile"))
    }

    init(tlvData: Data) throws(NIP19Entity.Error) {
        var publicKey: PublicKey?
        var relays: [RelayURL] = []
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                publicKey = try TLV.publicKey(record.value)
            case TLV.Kind.relay.rawValue:
                if let relay = TLV.relay(record) {
                    relays.append(relay)
                }
            default:
                continue
            }
        }
        guard let publicKey else {
            throw .missingPublicKey
        }
        self.publicKey = publicKey
        self.relays = relays
    }

    /// The canonical `nprofile` bech32 string.
    public var encoded: String {
        get throws(NIP19Entity.Error) {
            try TLV.bech32([TLV.specialRecord(publicKey)] + TLV.relayRecords(relays), prefix: "nprofile")
        }
    }
}
