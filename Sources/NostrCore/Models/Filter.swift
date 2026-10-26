import Foundation

/// Nostr Filter for subscriptions (NIP-01)
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct Filter: Codable, Sendable, Hashable {
    /// The ids of the events to match.
    public var ids: [EventID]?

    /// The public keys of the authors to match.
    public var authors: [PublicKey]?

    /// List of event kinds
    public var kinds: [Event.Kind]?

    /// Event ids to match against the events' "e" tags (`#e` on the wire).
    public var eventReferences: [EventID]?

    /// Public keys to match against the events' "p" tags (`#p` on the wire).
    public var publicKeyReferences: [PublicKey]?

    /// The earliest `created_at` to match, inclusive.
    public var since: Timestamp?

    /// The latest `created_at` to match, inclusive.
    public var until: Timestamp?

    /// Maximum number of events to be returned
    public var limit: Int?

    /// Free-text search query (NIP-50). Relays that support search return events
    /// matching the query; relays without NIP-50 support may ignore this field.
    /// https://github.com/nostr-protocol/nips/blob/master/50.md
    public var search: String?

    /// Generic tag queries (e.g., #t for hashtags)
    private var tagQueries: [String: [String]]

    enum CodingKeys: String, CodingKey {
        case ids
        case authors
        case kinds
        case eventReferences = "#e"
        case publicKeyReferences = "#p"
        case since
        case until
        case limit
        case search
    }

    /// Creates a filter. Every condition is optional; a nil condition matches everything.
    ///
    /// Ids and public keys encode as their canonical hex strings, the NIP-01 wire form.
    public init(
        ids: [EventID]? = nil,
        authors: [PublicKey]? = nil,
        kinds: [Event.Kind]? = nil,
        eventReferences: [EventID]? = nil,
        publicKeyReferences: [PublicKey]? = nil,
        since: Timestamp? = nil,
        until: Timestamp? = nil,
        limit: Int? = nil,
        search: String? = nil
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.eventReferences = eventReferences
        self.publicKeyReferences = publicKeyReferences
        self.since = since
        self.until = until
        self.limit = limit
        self.search = search
        self.tagQueries = [:]
    }

    /// Decodes a NIP-01 filter object.
    /// - Throws: `DecodingError.dataCorrupted` if `ids`, `authors`, `#e`, or `#p` holds a value
    ///   that is not a canonical 64-digit lowercase hex id or public key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ids = try container.decodeIfPresent([EventID].self, forKey: .ids)
        authors = try container.decodeIfPresent([PublicKey].self, forKey: .authors)
        kinds = try container.decodeIfPresent([Event.Kind].self, forKey: .kinds)
        eventReferences = try container.decodeIfPresent([EventID].self, forKey: .eventReferences)
        publicKeyReferences = try container.decodeIfPresent([PublicKey].self, forKey: .publicKeyReferences)
        since = try container.decodeIfPresent(Timestamp.self, forKey: .since)
        until = try container.decodeIfPresent(Timestamp.self, forKey: .until)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        search = try container.decodeIfPresent(String.self, forKey: .search)

        // Decode generic tag queries
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var tagQueries: [String: [String]] = [:]
        for key in dynamicContainer.allKeys {
            if key.stringValue.hasPrefix("#") && key.stringValue != "#e" && key.stringValue != "#p" {
                tagQueries[key.stringValue] = try dynamicContainer.decode([String].self, forKey: key)
            }
        }
        self.tagQueries = tagQueries
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(ids, forKey: .ids)
        try container.encodeIfPresent(authors, forKey: .authors)
        try container.encodeIfPresent(kinds, forKey: .kinds)
        try container.encodeIfPresent(eventReferences, forKey: .eventReferences)
        try container.encodeIfPresent(publicKeyReferences, forKey: .publicKeyReferences)
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(until, forKey: .until)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(search, forKey: .search)

        // Encode generic tag queries
        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKeys.self)
        for (key, value) in tagQueries {
            try dynamicContainer.encode(value, forKey: DynamicCodingKeys(stringValue: key)!)
        }
    }

    /// Adds a generic tag query, encoded as `#<name>` (e.g. `#t` for hashtags), replacing any
    /// existing query for the same tag.
    ///
    /// A leading `#` in `name` is ignored: `addTagQuery(.hashtag, values:)` and
    /// `addTagQuery("#t", values:)` set the same `#t` query.
    public mutating func addTagQuery(_ name: Tag.Name, values: [String]) {
        tagQueries[Self.tagQueryKey(for: name)] = values
    }

    /// Returns the values of a generic tag query (e.g. `#t` for hashtags).
    ///
    /// A leading `#` in `name` is ignored: `tagQuery(.hashtag)` and `tagQuery("#t")` look up
    /// the same query.
    public func tagQuery(_ name: Tag.Name) -> [String]? {
        tagQueries[Self.tagQueryKey(for: name)]
    }

    private static func tagQueryKey(for name: Tag.Name) -> String {
        name.rawValue.hasPrefix("#") ? name.rawValue : "#\(name.rawValue)"
    }
}

// MARK: - Dynamic Coding Keys
private struct DynamicCodingKeys: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

// MARK: - Convenience Initializers
extension Filter {
    /// Create a filter for a specific user's notes
    public static func userNotes(publicKey: PublicKey, limit: Int? = nil) -> Filter {
        Filter(
            authors: [publicKey],
            kinds: [.textNote],
            limit: limit
        )
    }

    /// Create a filter for metadata of specific users
    public static func metadata(publicKeys: [PublicKey]) -> Filter {
        Filter(
            authors: publicKeys,
            kinds: [.setMetadata]
        )
    }

    /// Create a filter for replies to a specific event
    public static func replies(to eventID: EventID, limit: Int? = nil) -> Filter {
        Filter(
            kinds: [.textNote],
            eventReferences: [eventID],
            limit: limit
        )
    }

    /// Create a filter for mentions of a specific user
    public static func mentions(publicKey: PublicKey, limit: Int? = nil) -> Filter {
        Filter(
            kinds: [.textNote],
            publicKeyReferences: [publicKey],
            limit: limit
        )
    }

    /// Create a filter for a global feed
    public static func globalFeed(limit: Int = 100) -> Filter {
        Filter(
            kinds: [.textNote],
            limit: limit
        )
    }

    /// Create a filter for contact lists of specific users (NIP-02)
    public static func contactList(publicKeys: [PublicKey]) -> Filter {
        Filter(
            authors: publicKeys,
            kinds: [.contacts]
        )
    }

    /// Create a filter for a specific user's contact list (NIP-02)
    public static func contactList(publicKey: PublicKey) -> Filter {
        Filter(
            authors: [publicKey],
            kinds: [.contacts],
            limit: 1
        )
    }

    /// Create a filter for relay list metadata of specific users (NIP-65)
    public static func relayListMetadata(publicKeys: [PublicKey]) -> Filter {
        Filter(
            authors: publicKeys,
            kinds: [.relayListMetadata]
        )
    }

    /// Create a filter for a specific user's relay list metadata (NIP-65)
    public static func relayListMetadata(publicKey: PublicKey) -> Filter {
        Filter(
            authors: [publicKey],
            kinds: [.relayListMetadata],
            limit: 1
        )
    }

    /// Create a filter for DM relay lists of specific users (NIP-17, kind 10050)
    public static func directMessageRelayList(publicKeys: [PublicKey]) -> Filter {
        Filter(
            authors: publicKeys,
            kinds: [.directMessageRelayList]
        )
    }

    /// Create a filter for a specific user's DM relay list (NIP-17, kind 10050)
    public static func directMessageRelayList(publicKey: PublicKey) -> Filter {
        Filter(
            authors: [publicKey],
            kinds: [.directMessageRelayList],
            limit: 1
        )
    }

    /// Create a filter for a free-text relay search (NIP-50)
    public static func search(_ query: String, kinds: [Event.Kind]? = nil, limit: Int? = nil) -> Filter {
        Filter(
            kinds: kinds,
            limit: limit,
            search: query
        )
    }

    /// Create a filter for the content timeline of a NIP-29 group (events carrying its "h" tag).
    ///
    /// Pass nil `kinds` (the default) to match all content kinds.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public static func groupTimeline(
        groupID: String,
        kinds: [Event.Kind]? = nil,
        since: Timestamp? = nil,
        limit: Int? = nil
    ) -> Filter {
        var filter = Filter(
            kinds: kinds,
            since: since,
            limit: limit
        )
        filter.addTagQuery(.group, values: [groupID])
        return filter
    }

    /// Create a filter for the relay-generated state of a NIP-29 group (kind-39xxx events
    /// carrying its "d" tag).
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public static func groupState(
        groupID: String,
        kinds: [Event.Kind] = [.groupMetadata, .groupAdmins, .groupMembers, .groupRoles, .groupPinList]
    ) -> Filter {
        var filter = Filter(kinds: kinds)
        filter.addTagQuery(.identifier, values: [groupID])
        return filter
    }
}
