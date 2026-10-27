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
    ///
    /// This is a typed view of `self[tag: .event]`: both read and write the same `#e` query.
    /// Values set through the subscript that are not canonical hex event ids are left out of this
    /// view, but stay in the query and are encoded.
    public var eventReferences: [EventID]? {
        get { tagQueries[.event].map { $0.compactMap(EventID.init) } }
        set { tagQueries[.event] = newValue.map { $0.map(\.hex) } }
    }

    /// Public keys to match against the events' "p" tags (`#p` on the wire).
    ///
    /// This is a typed view of `self[tag: .publicKey]`: both read and write the same `#p` query.
    /// Values set through the subscript that are not canonical hex public keys are left out of this
    /// view, but stay in the query and are encoded.
    public var publicKeyReferences: [PublicKey]? {
        get { tagQueries[.publicKey].map { $0.compactMap(PublicKey.init) } }
        set { tagQueries[.publicKey] = newValue.map { $0.map(\.hex) } }
    }

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

    /// Every tag query, `#e` and `#p` included, keyed by tag name; each encodes as `#<name>`.
    private var tagQueries: [Tag.Name: [String]]

    enum CodingKeys: String, CodingKey {
        case ids
        case authors
        case kinds
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
        self.since = since
        self.until = until
        self.limit = limit
        self.search = search
        self.tagQueries = [:]
        self.eventReferences = eventReferences
        self.publicKeyReferences = publicKeyReferences
    }

    /// The values of the query on the tag named `name`, encoded as `#<name>` (e.g. `#t` for
    /// `.hashtag`); assigning nil removes the query.
    ///
    ///     filter[tag: .hashtag] = ["nostr"]
    ///
    /// `self[tag: .event]` and `self[tag: .publicKey]` are the same `#e` and `#p` queries as
    /// ``eventReferences`` and ``publicKeyReferences``, as hex strings. Values assigned to them
    /// are kept and encoded as given, even if they are not canonical hex; the typed properties
    /// leave such values out, and decoding a filter that holds them throws.
    public subscript(tag name: Tag.Name) -> [String]? {
        get { tagQueries[name] }
        set { tagQueries[name] = newValue }
    }

    /// Decodes a NIP-01 filter object.
    /// - Throws: `DecodingError.dataCorrupted` if `ids`, `authors`, `#e`, or `#p` holds a value
    ///   that is not a canonical 64-digit lowercase hex id or public key.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        ids = try container.decodeIfPresent([EventID].self, forKey: .ids)
        authors = try container.decodeIfPresent([PublicKey].self, forKey: .authors)
        kinds = try container.decodeIfPresent([Event.Kind].self, forKey: .kinds)
        since = try container.decodeIfPresent(Timestamp.self, forKey: .since)
        until = try container.decodeIfPresent(Timestamp.self, forKey: .until)
        limit = try container.decodeIfPresent(Int.self, forKey: .limit)
        search = try container.decodeIfPresent(String.self, forKey: .search)

        let tagContainer = try decoder.container(keyedBy: DynamicCodingKeys.self)
        var tagQueries: [Tag.Name: [String]] = [:]
        for key in tagContainer.allKeys where key.stringValue.hasPrefix("#") {
            let name = Tag.Name(rawValue: String(key.stringValue.dropFirst()))
            switch name {
            case .event:
                tagQueries[name] = try tagContainer.decode([EventID].self, forKey: key).map(\.hex)
            case .publicKey:
                tagQueries[name] = try tagContainer.decode([PublicKey].self, forKey: key).map(\.hex)
            default:
                tagQueries[name] = try tagContainer.decode([String].self, forKey: key)
            }
        }
        self.tagQueries = tagQueries
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encodeIfPresent(ids, forKey: .ids)
        try container.encodeIfPresent(authors, forKey: .authors)
        try container.encodeIfPresent(kinds, forKey: .kinds)
        try container.encodeIfPresent(since, forKey: .since)
        try container.encodeIfPresent(until, forKey: .until)
        try container.encodeIfPresent(limit, forKey: .limit)
        try container.encodeIfPresent(search, forKey: .search)

        var tagContainer = encoder.container(keyedBy: DynamicCodingKeys.self)
        for (name, values) in tagQueries {
            try tagContainer.encode(values, forKey: DynamicCodingKeys(stringValue: "#\(name.rawValue)")!)
        }
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
        filter[tag: .group] = [groupID]
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
        filter[tag: .identifier] = [groupID]
        return filter
    }
}
