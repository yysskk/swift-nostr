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

    /// Event kind (integer)
    public let kind: Int

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
        kind: Int,
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

// MARK: - Event Kind Constants
extension Event {
    /// Common event kinds defined in NIPs
    public enum Kind: Int, Sendable {
        case setMetadata = 0
        case textNote = 1
        case recommendRelay = 2
        case contacts = 3
        case encryptedDirectMessage = 4
        case eventDeletion = 5
        case repost = 6
        case reaction = 7
        case badgeAward = 8
        case channelCreation = 40
        case channelMetadata = 41
        case channelMessage = 42
        case channelHideMessage = 43
        case channelMuteUser = 44
        case fileMetadata = 1063
        case report = 1984
        case label = 1985
        case zapRequest = 9734
        case zap = 9735
        case muteList = 10000
        case pinList = 10001
        case relayListMetadata = 10002
        case clientAuthentication = 22242
        case nostrConnect = 24133
        case categorizedPeopleList = 30000
        case categorizedBookmarkList = 30001
        case profileBadges = 30008
        case badgeDefinition = 30009
        case longFormContent = 30023
        case applicationSpecificData = 30078

        // NIP-17 Private Direct Messages
        case privateDirectMessage = 14
        case seal = 13
        case giftWrap = 1059
    }
}

// MARK: - Unsigned Event
/// An event before it has been signed
public struct UnsignedEvent: Sendable {
    public let pubkey: String
    public let createdAt: Int64
    public let kind: Int
    /// Tags in their raw NIP-01 wire form (what is hashed and signed).
    public let tags: [[String]]
    public let content: String

    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Int,
        tags: [Tag] = [],
        content: String
    ) {
        self.init(pubkey: pubkey, createdAt: createdAt, kind: kind, rawTags: tags.map(\.rawArray), content: content)
    }

    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Event.Kind,
        tags: [Tag] = [],
        content: String
    ) {
        self.init(pubkey: pubkey, createdAt: createdAt, kind: kind.rawValue, tags: tags, content: content)
    }

    /// Builds an unsigned event from raw NIP-01 tag arrays, e.g. tags copied
    /// from another event. Prefer the ``Tag``-based initializers when
    /// constructing tags yourself.
    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Int,
        rawTags: [[String]],
        content: String
    ) {
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.kind = kind
        self.tags = rawTags
        self.content = content
    }

    /// Builds an unsigned event of a known kind from raw NIP-01 tag arrays.
    public init(
        pubkey: String,
        createdAt: Int64 = Int64(Date().timeIntervalSince1970),
        kind: Event.Kind,
        rawTags: [[String]],
        content: String
    ) {
        self.init(pubkey: pubkey, createdAt: createdAt, kind: kind.rawValue, rawTags: rawTags, content: content)
    }

    /// Serializes the event for hashing according to NIP-01
    public func serializedForHashing() throws -> Data {
        let serializable: [Any] = [
            0,
            pubkey,
            createdAt,
            kind,
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
