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
    /// A private key. Like ``PrivateKey`` itself, the entity's description never shows it.
    case nsec(PrivateKey)
    /// An event id.
    case note(EventID)
    /// A profile reference with optional relay hints.
    case nprofile(NProfile)
    /// An event reference with optional relay hints, author, and kind.
    case nevent(NEvent)
    /// An addressable (parameterized replaceable) event coordinate.
    case naddr(NAddr)

    /// Decodes any NIP-19 bech32 entity, dispatching on its human-readable prefix.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if the string is not valid bech32,
    ///   ``NIP19Entity/Error/unknownPrefix(_:)`` for a prefix NIP-19 does not define,
    ///   ``NIP19Entity/Error/invalidLength(_:)`` if an `npub`, `nsec`, or `note` payload is not
    ///   32 bytes, ``NIP19Entity/Error/invalidPrivateKey`` if an `nsec` payload is not a valid
    ///   secp256k1 scalar, or the errors of decoding an `nprofile`, `nevent`, or `naddr` payload.
    public static func decode(_ bech32String: String) throws(NIP19Entity.Error) -> NIP19Entity {
        let (hrp, data) = try TLV.decodeBech32(bech32String)
        switch hrp {
        case "npub":
            return .npub(try TLV.publicKey(data))
        case "nsec":
            do throws(KeyPair.Error) {
                return .nsec(try PrivateKey(data: data))
            } catch .invalidLength(let count) {
                throw .invalidLength(count)
            } catch {
                throw .invalidPrivateKey
            }
        case "note":
            return .note(try TLV.eventID(data))
        case "nprofile":
            return .nprofile(try NProfile(tlvData: data))
        case "nevent":
            return .nevent(try NEvent(tlvData: data))
        case "naddr":
            return .naddr(try NAddr(tlvData: data))
        default:
            throw .unknownPrefix(hrp)
        }
    }

    /// The canonical bech32-encoded string for this entity.
    /// - Throws: The errors of encoding an `nprofile`, `nevent`, or `naddr`.
    public var encoded: String {
        get throws(NIP19Entity.Error) {
            switch self {
            case .npub(let publicKey):
                return publicKey.npub
            case .nsec(let privateKey):
                return privateKey.nsec
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

    /// An error decoding or encoding a NIP-19 entity or a NIP-21 `nostr:` URI.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string is not valid bech32.
        case invalidBech32(Bech32.Error)
        /// The bech32 prefix is not one NIP-19 defines (payload: the prefix found).
        case unknownPrefix(String)
        /// The bech32 prefix is not the one the entity type expects, such as an `npub` given to
        /// ``NProfile/init(bech32String:)`` (payload: the prefix found).
        case unexpectedPrefix(String)
        /// A TLV record runs past the end of the payload.
        case malformedTLV
        /// An `nprofile` has no public key record.
        case missingPublicKey
        /// An `nevent` has no event id record.
        case missingEventID
        /// An `naddr` has no `d`-tag identifier record.
        case missingIdentifier
        /// An `naddr` has no author record.
        case missingAuthor
        /// An `naddr` has no kind record.
        case missingKind
        /// A public key, private key, or event id is not 32 bytes, or a kind record is not 1–4
        /// bytes (payload: the byte count).
        case invalidLength(Int)
        /// A field is longer than the 255 bytes a TLV record can hold (payload: its byte count).
        case fieldTooLong(Int)
        /// The event kind does not fit in a 32-bit unsigned integer (payload: the kind).
        case kindOutOfRange(Event.Kind)
        /// An `nsec` payload is not a valid secp256k1 private key: zero, or not below the curve
        /// order.
        case invalidPrivateKey
        /// The string does not start with the `nostr:` scheme.
        case missingNostrScheme
        /// The `nostr:` URI holds an `nsec`, or an `nsec` was to be encoded as one; NIP-21 never
        /// carries private keys.
        case privateKeyInURI

        public var errorDescription: String? {
            switch self {
            case .invalidBech32(let error):
                return "Invalid NIP-19 entity: \(error.errorDescription ?? "invalid bech32")"
            case .unknownPrefix(let prefix):
                return "Unknown NIP-19 prefix: \(prefix)"
            case .unexpectedPrefix(let prefix):
                return "Unexpected NIP-19 prefix: \(prefix)"
            case .malformedTLV:
                return "A NIP-19 TLV record is truncated"
            case .missingPublicKey:
                return "An nprofile must carry a public key"
            case .missingEventID:
                return "An nevent must carry an event id"
            case .missingIdentifier:
                return "An naddr must carry an identifier"
            case .missingAuthor:
                return "An naddr must carry an author"
            case .missingKind:
                return "An naddr must carry a kind"
            case .invalidLength(let count):
                return "A NIP-19 field has the wrong length: \(count) bytes"
            case .fieldTooLong(let count):
                return "A NIP-19 TLV field must be at most 255 bytes, got \(count)"
            case .kindOutOfRange(let kind):
                return "A NIP-19 kind must fit in 32 bits, got \(kind)"
            case .invalidPrivateKey:
                return "An nsec must hold a valid secp256k1 private key"
            case .missingNostrScheme:
                return "A nostr URI must start with nostr:"
            case .privateKeyInURI:
                return "A nostr URI must not carry an nsec"
            }
        }
    }
}
