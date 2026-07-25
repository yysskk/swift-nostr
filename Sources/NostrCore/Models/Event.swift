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
        /// A chat message (NIP-C7), commonly posted into NIP-29 relay-based groups with an "h" tag.
        /// https://github.com/nostr-protocol/nips/blob/master/C7.md
        public static let chatMessage = Kind(rawValue: 9)
        /// A thread root post (NIP-7D), replied to with kind-1111 comments.
        /// https://github.com/nostr-protocol/nips/blob/master/7D.md
        public static let thread = Kind(rawValue: 11)
        public static let seal = Kind(rawValue: 13)
        public static let privateDirectMessage = Kind(rawValue: 14)
        public static let fileMessage = Kind(rawValue: 15)
        public static let channelCreation = Kind(rawValue: 40)
        public static let channelMetadata = Kind(rawValue: 41)
        public static let channelMessage = Kind(rawValue: 42)
        public static let channelHideMessage = Kind(rawValue: 43)
        public static let channelMuteUser = Kind(rawValue: 44)
        public static let giftWrap = Kind(rawValue: 1059)
        public static let fileMetadata = Kind(rawValue: 1063)
        public static let report = Kind(rawValue: 1984)
        public static let label = Kind(rawValue: 1985)
        /// A NIP-29 moderation event adding a user to a group and/or updating their roles,
        /// sent by a group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupPutUser = Kind(rawValue: 9000)
        /// A NIP-29 moderation event removing a user from a group, sent by a group admin
        /// or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupRemoveUser = Kind(rawValue: 9001)
        /// A NIP-29 moderation event editing a group's metadata (name, picture, visibility),
        /// sent by a group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupEditMetadata = Kind(rawValue: 9002)
        /// A NIP-29 moderation event deleting an event from a group, sent by a group admin
        /// or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupDeleteEvent = Kind(rawValue: 9005)
        /// A NIP-29 moderation event creating a group, sent by a group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupCreation = Kind(rawValue: 9007)
        /// A NIP-29 moderation event deleting a group, sent by a group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupDeletion = Kind(rawValue: 9008)
        /// A NIP-29 moderation event creating an invite code for a closed group, sent by a
        /// group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupCreateInvite = Kind(rawValue: 9009)
        /// A NIP-29 moderation event updating a group's list of pinned events, sent by a
        /// group admin or the relay itself.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupUpdatePinList = Kind(rawValue: 9010)
        /// A NIP-29 request from a user to join a group, optionally carrying an invite code.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupJoinRequest = Kind(rawValue: 9021)
        /// A NIP-29 request from a user to leave a group.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupLeaveRequest = Kind(rawValue: 9022)
        public static let zapRequest = Kind(rawValue: 9734)
        public static let zap = Kind(rawValue: 9735)
        public static let muteList = Kind(rawValue: 10000)
        public static let pinList = Kind(rawValue: 10001)
        public static let relayListMetadata = Kind(rawValue: 10002)
        /// A NIP-51 bookmark list (public/private bookmarked events, articles, hashtags, URLs).
        public static let bookmarkList = Kind(rawValue: 10003)
        /// The NIP-51 "Simple groups" list: the NIP-29 groups a user is in.
        /// https://github.com/nostr-protocol/nips/blob/master/51.md
        public static let simpleGroupList = Kind(rawValue: 10009)
        public static let directMessageRelayList = Kind(rawValue: 10050)
        public static let clientAuthentication = Kind(rawValue: 22242)
        /// A NIP-98 HTTP authorization event, carried base64-encoded in an
        /// `Authorization: Nostr <event>` header rather than published to relays.
        /// https://github.com/nostr-protocol/nips/blob/master/98.md
        public static let httpAuth = Kind(rawValue: 27235)
        public static let nostrConnect = Kind(rawValue: 24133)
        public static let categorizedPeopleList = Kind(rawValue: 30000)
        /// The legacy NIP-51 categorized bookmarks kind, superseded by bookmark sets (30003).
        public static let categorizedBookmarkList = Kind(rawValue: 30001)
        /// A NIP-51 follow set: a categorized set of profiles.
        ///
        /// Shares raw value 30000 with ``categorizedPeopleList`` — the standard-list and set
        /// names refer to the same addressable kind.
        public static let followSet = Kind(rawValue: 30000)
        /// A NIP-51 relay set: a categorized set of relays.
        public static let relaySet = Kind(rawValue: 30002)
        /// A NIP-51 bookmark set: a categorized set of bookmarked events, articles, hashtags, URLs.
        public static let bookmarkSet = Kind(rawValue: 30003)
        /// A NIP-51 curation set: a categorized set of articles and notes.
        public static let curationSet = Kind(rawValue: 30004)
        /// A NIP-51 video curation set: a categorized set of videos.
        public static let videoCurationSet = Kind(rawValue: 30005)
        /// A NIP-51 picture curation set: a categorized set of pictures.
        public static let pictureCurationSet = Kind(rawValue: 30006)
        /// A NIP-51 kind mute set: a categorized set of muted event kinds.
        public static let kindMuteSet = Kind(rawValue: 30007)
        /// A NIP-51 interest set: a categorized set of interest hashtags.
        public static let interestSet = Kind(rawValue: 30015)
        /// A NIP-51 emoji set: a categorized set of custom emoji.
        public static let emojiSet = Kind(rawValue: 30030)
        public static let profileBadges = Kind(rawValue: 30008)
        public static let badgeDefinition = Kind(rawValue: 30009)
        public static let longFormContent = Kind(rawValue: 30023)
        /// A NIP-23 long-form draft: an unpublished article, addressed by a `d` tag like ``longFormContent``.
        /// https://github.com/nostr-protocol/nips/blob/master/23.md
        public static let longFormDraft = Kind(rawValue: 30024)
        public static let applicationSpecificData = Kind(rawValue: 30078)
        /// A NIP-29 group's metadata (name, picture, about, visibility), generated and signed
        /// by the group's relay with the group id in a "d" tag — clients parse these events,
        /// never publish them.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupMetadata = Kind(rawValue: 39000)
        /// A NIP-29 group's admins and their roles, generated and signed by the group's relay
        /// with the group id in a "d" tag — clients parse these events, never publish them.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupAdmins = Kind(rawValue: 39001)
        /// A NIP-29 group's members, generated and signed by the group's relay with the group
        /// id in a "d" tag — clients parse these events, never publish them.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupMembers = Kind(rawValue: 39002)
        /// A NIP-29 group's supported roles, generated and signed by the group's relay with
        /// the group id in a "d" tag — clients parse these events, never publish them.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupRoles = Kind(rawValue: 39003)
        /// A NIP-29 group's pinned events, generated and signed by the group's relay with the
        /// group id in a "d" tag — clients parse these events, never publish them.
        /// https://github.com/nostr-protocol/nips/blob/master/29.md
        public static let groupPinList = Kind(rawValue: 39005)
    }
}

extension Event.Kind: Codable {
    /// Encodes and decodes as a bare integer, matching the NIP-01 wire format.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Unsigned Event
/// An event before it has been signed
public struct UnsignedEvent: Sendable {
    /// The creator's public key (32-byte lowercase hex).
    public let pubkey: String
    /// Creation time as a Unix timestamp in seconds.
    public let createdAt: Int64
    /// The event kind (NIP-01).
    public let kind: Event.Kind
    /// Tags in their raw NIP-01 wire form (what is hashed and signed).
    public let tags: [[String]]
    /// The event's content; its meaning depends on ``kind``.
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

    /// The NIP-01 event id: the lowercase hex SHA-256 of ``serializedForHashing()``.
    ///
    /// This is the single source of truth for deriving an event id from its
    /// unsigned form; signing, rumor construction, and proof-of-work mining all
    /// go through it.
    public var computedId: String {
        get throws {
            try Data(SHA256.hash(data: serializedForHashing())).hexEncodedString()
        }
    }

    /// Returns this event as an unsigned rumor (NIP-59): the event id is computed
    /// from the serialized form, but no signature is ever produced (`sig` is empty).
    ///
    /// NIP-17 requires that kind-14 rumors are never signed — a leaked signed rumor
    /// would be cryptographic proof of authorship and destroy deniability.
    /// https://github.com/nostr-protocol/nips/blob/master/59.md
    public func asRumor() throws -> Event {
        Event(
            id: try computedId,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: ""
        )
    }
}
