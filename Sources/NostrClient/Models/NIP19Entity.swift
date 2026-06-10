import Foundation

/// A NIP-19 bech32-encoded entity.
///
/// Provides a single entry point for decoding any `npub`, `nsec`, `note`,
/// `nprofile`, `nevent`, or `naddr` string, and for re-encoding it back to
/// its canonical bech32 form.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public enum NIP19Entity: Sendable, Hashable {
    /// A public key (32-byte hex).
    case npub(String)
    /// A private key (32-byte hex).
    case nsec(String)
    /// An event id (32-byte hex).
    case note(String)
    /// A profile reference with optional relay hints.
    case nprofile(NProfile)
    /// An event reference with optional relay hints, author, and kind.
    case nevent(NEvent)
    /// An addressable (parameterized replaceable) event coordinate.
    case naddr(NAddr)

    /// Decodes any NIP-19 bech32 entity, dispatching on its human-readable prefix.
    public static func decode(_ bech32String: String) throws -> NIP19Entity {
        let (hrp, data) = try Bech32.decode(bech32String)
        switch hrp {
        case "npub":
            return .npub(try bareHex32(data))
        case "nsec":
            return .nsec(try bareHex32(data))
        case "note":
            return .note(try bareHex32(data))
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
    public var encoded: String {
        switch self {
        case .npub(let hex):
            return Bech32.encode(hrp: "npub", data: Data(hexString: hex) ?? Data())
        case .nsec(let hex):
            return Bech32.encode(hrp: "nsec", data: Data(hexString: hex) ?? Data())
        case .note(let hex):
            return Bech32.encode(hrp: "note", data: Data(hexString: hex) ?? Data())
        case .nprofile(let profile):
            return profile.encoded
        case .nevent(let event):
            return event.encoded
        case .naddr(let addr):
            return addr.encoded
        }
    }
}

/// Validates a bare 32-byte payload (npub/nsec/note) and returns its hex form.
private func bareHex32(_ data: Data) throws -> String {
    guard data.count == 32 else {
        throw NostrError.invalidNIP19Entity
    }
    return data.hexEncodedString()
}
