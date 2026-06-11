import Crypto
import Foundation

/// Nostr Event (NIP-01)
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct Event: Codable, Identifiable, Hashable, Sendable {
    /// 32-byte lowercase hex-encoded sha256 of the serialized event data
    public let id: String

    /// 32-byte lowercase hex-encoded public key of the event creator
    public let pubkey: String

    /// Unix timestamp in seconds
    public let createdAt: Int64

    /// Event kind. Encodes as a bare integer (NIP-01); integer literals convert
    /// directly, e.g. `kind: 1`.
    public let kind: Kind

    /// Array of arrays of strings (tags)
    public let tags: [[String]]

    /// Arbitrary string content
    public let content: String

    /// 64-byte lowercase hex-encoded signature
    public let sig: String

    enum CodingKeys: String, CodingKey {
        case id
        case pubkey
        case createdAt = "created_at"
        case kind
        case tags
        case content
        case sig
    }

    public init(
        id: String,
        pubkey: String,
        createdAt: Int64,
        kind: Kind,
        tags: [[String]],
        content: String,
        sig: String
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = tags
        self.content = content
        self.sig = sig
    }
}

// MARK: - Event Kind
extension Event {
    /// A Nostr event kind.
    ///
    /// Kinds are open-ended (NIP-01), so this is a `RawRepresentable` struct
    /// rather than a closed enum: any integer kind can be represented, with the
    /// kinds defined in NIPs available as static constants. Integer literals
    /// convert directly (`let kind: Event.Kind = 1`), and the value encodes to
    /// and from JSON as a bare integer.
    public struct Kind: RawRepresentable, Sendable, Hashable, Comparable,
        ExpressibleByIntegerLiteral, CustomStringConvertible
    {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public init(integerLiteral value: Int) {
            self.init(rawValue: value)
        }

        public static func < (lhs: Kind, rhs: Kind) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var description: String {
            String(rawValue)
        }

        // MARK: NIP-01 Range Semantics

        /// Replaceable kinds: relays keep only the latest event per pubkey
        /// (0, 3, and 10000-19999).
        public var isReplaceable: Bool {
            rawValue == 0 || rawValue == 3 || (10000..<20000).contains(rawValue)
        }

        /// Ephemeral kinds: relays do not store these events (20000-29999).
        public var isEphemeral: Bool {
            (20000..<30000).contains(rawValue)
        }

        /// Addressable kinds: replaceable per pubkey and "d" tag (30000-39999).
        public var isAddressable: Bool {
            (30000..<40000).contains(rawValue)
        }

        // MARK: Common Kinds Defined in NIPs

        public static let setMetadata = Kind(rawValue: 0)
        public static let textNote = Kind(rawValue: 1)
        public static let recommendRelay = Kind(rawValue: 2)
        public static let contacts = Kind(rawValue: 3)
        public static let encryptedDirectMessage = Kind(rawValue: 4)
        public static let eventDeletion = Kind(rawValue: 5)
        public static let repost = Kind(rawValue: 6)
        public static let reaction = Kind(rawValue: 7)
        public static let badgeAward = Kind(rawValue: 8)
        public static let seal = Kind(rawValue: 13)
        public static let privateDirectMessage = Kind(rawValue: 14)
        public static let channelCreation = Kind(rawValue: 40)
        public static let channelMetadata = Kind(rawValue: 41)
        public static let channelMessage = Kind(rawValue: 42)
        public static let channelHideMessage = Kind(rawValue: 43)
        public static let channelMuteUser = Kind(rawValue: 44)
        public static let giftWrap = Kind(rawValue: 1059)
        public static let fileMetadata = Kind(rawValue: 1063)
        public static let report = Kind(rawValue: 1984)
        public static let label = Kind(rawValue: 1985)
        public static let zapRequest = Kind(rawValue: 9734)
        public static let zap = Kind(rawValue: 9735)
        public static let muteList = Kind(rawValue: 10000)
        public static let pinList = Kind(rawValue: 10001)
        public static let relayListMetadata = Kind(rawValue: 10002)
        public static let clientAuthentication = Kind(rawValue: 22242)
        public static let nostrConnect = Kind(rawValue: 24133)
        public static let categorizedPeopleList = Kind(rawValue: 30000)
        public static let categorizedBookmarkList = Kind(rawValue: 30001)
        public static let profileBadges = Kind(rawValue: 30008)
        public static let badgeDefinition = Kind(rawValue: 30009)
        public static let longFormContent = Kind(rawValue: 30023)
        public static let applicationSpecificData = Kind(rawValue: 30078)
    }
}

extension Event.Kind: Codable {
    /// Encodes and decodes as a bare integer, matching the NIP-01 wire format.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Unsigned Event
/// An event before it has been signed
public struct UnsignedEvent: Sendable {
    public let pubkey: String
    public let createdAt: Int64
    public let kind: Event.Kind
    /// Tags in their raw NIP-01 wire form (what is hashed and signed).
    public let tags: [[String]]
    public let content: String

    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Event.Kind,
        tags: [Tag] = [],
        content: String
    ) {
        self.init(pubkey: pubkey, createdAt: createdAt, kind: kind, rawTags: tags.map(\.rawArray), content: content)
    }

    /// Builds an unsigned event from raw NIP-01 tag arrays, e.g. tags copied
    /// from another event. Prefer the ``Tag``-based initializer when
    /// constructing tags yourself.
    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Event.Kind,
        rawTags: [[String]],
        content: String
    ) {
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = rawTags
        self.content = content
    }

    /// Serializes the event for hashing according to NIP-01
    public func serializedForHashing() throws -> Data {
        let serializable: [Any] = [
            0,
            pubkey,
            createdAt,
            kind.rawValue,
            tags,
            content,
        ]
        return try JSONSerialization.data(
            withJSONObject: serializable, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Returns this event as an unsigned rumor (NIP-59): the event id is computed
    /// from the serialized form, but no signature is ever produced (`sig` is empty).
    ///
    /// NIP-17 requires that kind-14 rumors are never signed — a leaked signed rumor
    /// would be cryptographic proof of authorship and destroy deniability.
    /// https://github.com/nostr-protocol/nips/blob/master/59.md
    public func asRumor() throws -> Event {
        let serialized = try serializedForHashing()
        let eventId = Data(SHA256.hash(data: serialized)).hexEncodedString()
        return Event(
            id: eventId,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: ""
        )
    }
}
