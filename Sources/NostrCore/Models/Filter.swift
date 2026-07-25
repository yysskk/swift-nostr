import Foundation

/// Nostr Filter for subscriptions (NIP-01)
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct Filter: Codable, Sendable, Hashable {
    /// List of event ids
    public var ids: [String]?

    /// List of pubkeys (authors)
    public var authors: [String]?

    /// List of event kinds
    public var kinds: [Event.Kind]?

    /// List of event ids that are referenced in "e" tags
    public var eventReferences: [String]?

    /// List of pubkeys that are referenced in "p" tags
    public var pubkeyReferences: [String]?

    /// Unix timestamp (seconds), events must be newer than this
    public var since: Int64?

    /// Unix timestamp (seconds), events must be older than this
    public var until: Int64?

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
        case pubkeyReferences = "#p"
        case since
        case until
        case limit
        case search
    }

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [Event.Kind]? = nil,
        eventReferences: [String]? = nil,
        pubkeyReferences: [String]? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        limit: Int? = nil,
        search: String? = nil
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.eventReferences = eventReferences
        self.pubkeyReferences = pubkeyReferences
        self.since = since
        self.until = until
        self.limit = limit
        self.search = search
        self.tagQueries = [:]
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ids = try container.decodeIfPresent([String].self, forKey: .ids)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        kinds = try container.decodeIfPresent([Event.Kind].self, forKey: .kinds)
        eventReferences = try container.decodeIfPresent([String].self, forKey: .eventReferences)
        pubkeyReferences = try container.decodeIfPresent([String].self, forKey: .pubkeyReferences)
        since = try container.decodeIfPresent(Int64.self, forKey: .since)
        until = try container.decodeIfPresent(Int64.self, forKey: .until)
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
        try container.encodeIfPresent(pubkeyReferences, forKey: .pubkeyReferences)
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

    /// Add a generic tag query (e.g., #t for hashtags)
    public mutating func addTagQuery(_ tag: String, values: [String]) {
        let key = tag.hasPrefix("#") ? tag : "#\(tag)"
        tagQueries[key] = values
    }

    /// Returns the values of a generic tag query (e.g. `#t` for hashtags).
    ///
    /// The leading `#` may be omitted: `tagQuery("t")` and `tagQuery("#t")` look up
    /// the same query.
    public func tagQuery(_ tag: String) -> [String]? {
        let key = tag.hasPrefix("#") ? tag : "#\(tag)"
        return tagQueries[key]
    }

    /// Returns the values of a generic tag query.
    @available(*, deprecated, renamed: "tagQuery(_:)")
    public func getTagQuery(_ tag: String) -> [String]? {
        tagQuery(tag)
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
    public static func userNotes(pubkey: String, limit: Int? = nil) -> Filter {
        Filter(
            authors: [pubkey],
            kinds: [.textNote],
            limit: limit
        )
    }

    /// Create a filter for metadata of specific users
    public static func metadata(pubkeys: [String]) -> Filter {
        Filter(
            authors: pubkeys,
            kinds: [.setMetadata]
        )
    }

    /// Create a filter for replies to a specific event
    public static func replies(to eventId: String, limit: Int? = nil) -> Filter {
        Filter(
            kinds: [.textNote],
            eventReferences: [eventId],
            limit: limit
        )
    }

    /// Create a filter for mentions of a specific user
    public static func mentions(pubkey: String, limit: Int? = nil) -> Filter {
        Filter(
            kinds: [.textNote],
            pubkeyReferences: [pubkey],
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
    public static func contactList(pubkeys: [String]) -> Filter {
        Filter(
            authors: pubkeys,
            kinds: [.contacts]
        )
    }

    /// Create a filter for a specific user's contact list (NIP-02)
    public static func contactList(pubkey: String) -> Filter {
        Filter(
            authors: [pubkey],
            kinds: [.contacts],
            limit: 1
        )
    }

    /// Create a filter for relay list metadata of specific users (NIP-65)
    public static func relayListMetadata(pubkeys: [String]) -> Filter {
        Filter(
            authors: pubkeys,
            kinds: [.relayListMetadata]
        )
    }

    /// Create a filter for a specific user's relay list metadata (NIP-65)
    public static func relayListMetadata(pubkey: String) -> Filter {
        Filter(
            authors: [pubkey],
            kinds: [.relayListMetadata],
            limit: 1
        )
    }

    /// Create a filter for DM relay lists of specific users (NIP-17, kind 10050)
    public static func directMessageRelayList(pubkeys: [String]) -> Filter {
        Filter(
            authors: pubkeys,
            kinds: [.directMessageRelayList]
        )
    }

    /// Create a filter for a specific user's DM relay list (NIP-17, kind 10050)
    public static func directMessageRelayList(pubkey: String) -> Filter {
        Filter(
            authors: [pubkey],
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
        since: Int64? = nil,
        limit: Int? = nil
    ) -> Filter {
        var filter = Filter(
            kinds: kinds,
            since: since,
            limit: limit
        )
        filter.addTagQuery("h", values: [groupID])
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
        filter.addTagQuery("d", values: [groupID])
        return filter
    }
}
