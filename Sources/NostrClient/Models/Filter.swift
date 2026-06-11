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
    }

    public init(
        ids: [String]? = nil,
        authors: [String]? = nil,
        kinds: [Event.Kind]? = nil,
        eventReferences: [String]? = nil,
        pubkeyReferences: [String]? = nil,
        since: Int64? = nil,
        until: Int64? = nil,
        limit: Int? = nil
    ) {
        self.ids = ids
        self.authors = authors
        self.kinds = kinds
        self.eventReferences = eventReferences
        self.pubkeyReferences = pubkeyReferences
        self.since = since
        self.until = until
        self.limit = limit
        self.tagQueries = [:]
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ids = try container.decodeIfPresent([String].self, forKey: .ids)
        authors = try container.decodeIfPresent([String].self, forKey: .authors)
        kinds = try container.decodeIfPresent([Event.Kind].self, forKey: .kinds)
        eventReferences = try container.decodeIfPresent([String].self, forKey: .eventReferences)
        pubkeyReferences = try container.decodeIfPresent([String].self, forKey: .pubkeyReferences)
        since = try container.decodeIfPresent(Int64.self, forKey: .since)
        until = try container.decodeIfPresent(Int64.self, forKey: .until)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)

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

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(ids, forKey: .ids)
        try container.encodeIfPresent(authors, forKey: .authors)
        try container.encodeIfPresent(kinds, forKey: .kinds)
        try container.encodeIfPresent(eventReferences, forKey: .eventReferences)
        try container.encodeIfPresent(pubkeyReferences, forKey: .pubkeyReferences)
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(until, forKey: .until)
        try container.encodeIfPresent(limit, forKey: .limit)

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

    /// Get tag query values
    public func getTagQuery(_ tag: String) -> [String]? {
        let key = tag.hasPrefix("#") ? tag : "#\(tag)"
        return tagQueries[key]
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
}
