import Foundation
import NostrCore

/// A NIP-19 bech32-encoded entity.
///
/// Provides a single entry point for decoding any `npub`, `nsec`, `note`,
/// `nprofile`, `nevent`, or `naddr` string, and for re-encoding it back to
/// its canonical bech32 form.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public enum NIP19Entity: Sendable, Hashable {
    /// A public key.
    case npub(PublicKey)
    /// A private key (32-byte hex).
    case nsec(String)
    /// An event id.
    case note(EventID)
    /// A profile reference with optional relay hints.
    case nprofile(NProfile)
    /// An event reference with optional relay hints, author, and kind.
    case nevent(NEvent)
    /// An addressable (parameterized replaceable) event coordinate.
    case naddr(NAddr)

    /// Decodes any NIP-19 bech32 entity, dispatching on its human-readable prefix.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if an `npub`, `nsec`, or `note` payload is not
    ///   32 bytes or a TLV entity is missing a required field, ``NostrError/unknownPrefix(_:)`` for
    ///   any other prefix, or the bech32 and TLV decoding errors.
    public static func decode(_ bech32String: String) throws -> NIP19Entity {
        let (hrp, data) = try Bech32.decode(bech32String)
        switch hrp {
        case "npub":
            guard let publicKey = try? PublicKey(data: data) else { throw NostrError.invalidNIP19Entity }
            return .npub(publicKey)
        case "nsec":
            guard data.count == 32 else { throw NostrError.invalidNIP19Entity }
            return .nsec(data.hexEncodedString())
        case "note":
            guard let eventID = try? EventID(data: data) else { throw NostrError.invalidNIP19Entity }
            return .note(eventID)
        case "nprofile":
            return .nprofile(try NProfile(tlvData: data))
        case "nevent":
            return .nevent(try NEvent(tlvData: data))
        case "naddr":
            return .naddr(try NAddr(tlvData: data))
        default:
            throw NostrError.unknownPrefix(hrp)
        }
    }

    /// The canonical bech32-encoded string for this entity.
    ///
    /// ``nsec(_:)`` holds a hex string that nothing validated on the way in — every other case holds
    /// a typed key or id, or a payload built by a validating initializer — so it is checked here.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if ``nsec(_:)`` does not hold 32 bytes of hex.
    public var encoded: String {
        get throws {
            switch self {
            case .npub(let publicKey):
                return publicKey.npub
            case .nsec(let hex):
                // Without this check, invalid hex encoded as an empty payload: a checksum-valid
                // `nsec1…` holding no key.
                guard let data = Data(hexString: hex), data.count == 32 else {
                    throw NostrError.invalidNIP19Entity
                }
                return try Bech32.encode(hrp: "nsec", data: data)
            case .note(let eventID):
                return eventID.note
            case .nprofile(let profile):
                return try profile.encoded
            case .nevent(let event):
                return try event.encoded
            case .naddr(let addr):
                return try addr.encoded
            }
        }
    }
}
