import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("Filter Tests")
struct FilterTests {
    private let alice = PublicKey.fixture("alice")
    private let bob = PublicKey.fixture("bob")
    private let note = EventID.fixture("note")
    private let reply = EventID.fixture("reply")

    @Test("Create basic filter")
    func createBasicFilter() {
        let filter = Filter(
            authors: [alice, bob],
            kinds: [1],
            limit: 50
        )

        #expect(filter.authors == [alice, bob])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 50)
    }

    @Test("Filter with event references")
    func filterWithEventReferences() {
        let filter = Filter(
            kinds: [1],
            eventReferences: [note, reply]
        )

        #expect(filter.eventReferences == [note, reply])
    }

    @Test("Filter with public key references")
    func filterWithPublicKeyReferences() {
        let filter = Filter(
            kinds: [1],
            publicKeyReferences: [alice]
        )

        #expect(filter.publicKeyReferences == [alice])
    }

    @Test("Filter with time range")
    func filterWithTimeRange() {
        let now = Timestamp.now
        let hourAgo = Timestamp(rawValue: now.rawValue - 3600)
        let filter = Filter(
            since: hourAgo,
            until: now
        )

        #expect(filter.since == hourAgo)
        #expect(filter.until == now)
    }

    @Test("User notes convenience filter")
    func userNotesFilter() {
        let filter = Filter.userNotes(publicKey: alice, limit: 25)

        #expect(filter.authors == [alice])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 25)
    }

    @Test("Metadata convenience filter")
    func metadataFilter() {
        let filter = Filter.metadata(publicKeys: [alice, bob])

        #expect(filter.authors == [alice, bob])
        #expect(filter.kinds == [0])
    }

    @Test("Replies convenience filter")
    func repliesFilter() {
        let filter = Filter.replies(to: note, limit: 50)

        #expect(filter.eventReferences == [note])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 50)
    }

    @Test("Mentions convenience filter")
    func mentionsFilter() {
        let filter = Filter.mentions(publicKey: alice)

        #expect(filter.publicKeyReferences == [alice])
        #expect(filter.kinds == [1])
    }

    @Test("Global feed convenience filter")
    func globalFeedFilter() {
        let filter = Filter.globalFeed(limit: 100)

        #expect(filter.kinds == [1])
        #expect(filter.limit == 100)
    }

    @Test("Filter JSON encoding")
    func filterJSONEncoding() throws {
        let filter = Filter(
            authors: [alice],
            kinds: [1],
            eventReferences: [note],
            limit: 10
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(filter)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains("authors"))
        #expect(json.contains("kinds"))
        #expect(json.contains("#e"))
        #expect(json.contains("limit"))
    }

    @Test("Filter JSON decoding")
    func filterJSONDecoding() throws {
        let json = """
            {
                "ids": ["\(reply.hex)"],
                "authors": ["\(alice.hex)"],
                "kinds": [1, 7],
                "#e": ["\(note.hex)"],
                "#p": ["\(bob.hex)"],
                "limit": 50
            }
            """

        let decoder = JSONDecoder()
        let filter = try decoder.decode(Filter.self, from: json.data(using: .utf8)!)

        #expect(filter.ids == [reply])
        #expect(filter.authors == [alice])
        #expect(filter.kinds == [1, 7])
        #expect(filter.eventReferences == [note])
        #expect(filter.publicKeyReferences == [bob])
        #expect(filter.limit == 50)
    }

    @Test(
        "Filter JSON decoding rejects a malformed id or public key",
        arguments: ["ids", "authors", "#e", "#p"])
    func filterJSONDecodingRejectsMalformedValues(key: String) {
        let json = #"{"\#(key)": ["not-hex"]}"#

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Filter.self, from: Data(json.utf8))
        }
    }

    @Test("Profile list filters take public keys and encode them as hex authors")
    func profileListFilters() throws {
        let filters: [(Filter, Event.Kind, Int?)] = [
            (.followList(publicKey: alice), .followList, 1),
            (.relayListMetadata(publicKey: alice), .relayListMetadata, 1),
            (.directMessageRelayList(publicKey: alice), .directMessageRelayList, 1),
            (.followList(publicKeys: [alice]), .followList, nil),
            (.relayListMetadata(publicKeys: [alice]), .relayListMetadata, nil),
            (.directMessageRelayList(publicKeys: [alice]), .directMessageRelayList, nil),
        ]

        for (filter, kind, limit) in filters {
            let json = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(filter)) as? [String: Any])
            #expect(json["authors"] as? [String] == [alice.hex])
            #expect(filter.kinds == [kind])
            #expect(filter.limit == limit)
        }
    }

    @Test("Filter with search query")
    func filterWithSearch() {
        let filter = Filter(
            kinds: [1],
            limit: 20,
            search: "nostr"
        )

        #expect(filter.search == "nostr")
        #expect(filter.kinds == [1])
        #expect(filter.limit == 20)
    }

    @Test("Search convenience filter")
    func searchConvenienceFilter() {
        let filter = Filter.search("nostr", kinds: [.textNote], limit: 20)

        #expect(filter.search == "nostr")
        #expect(filter.kinds == [.textNote])
        #expect(filter.limit == 20)
    }

    @Test("Filter JSON encoding includes search")
    func filterJSONEncodingIncludesSearch() throws {
        let filter = Filter(kinds: [1], search: "nostr")

        let encoder = JSONEncoder()
        let data = try encoder.encode(filter)
        let json = String(data: data, encoding: .utf8)!

        #expect(json.contains(#""search":"nostr""#))
    }

    @Test("Filter JSON encoding omits search when nil")
    func filterJSONEncodingOmitsSearchWhenNil() throws {
        let filter = Filter(kinds: [1], limit: 10)

        let encoder = JSONEncoder()
        let data = try encoder.encode(filter)
        let json = String(data: data, encoding: .utf8)!

        #expect(!json.contains("search"))
    }

    @Test("Filter JSON decoding reads search")
    func filterJSONDecodingReadsSearch() throws {
        let json = """
            {
                "kinds": [1],
                "search": "nostr",
                "limit": 20
            }
            """

        let decoder = JSONDecoder()
        let filter = try decoder.decode(Filter.self, from: json.data(using: .utf8)!)

        #expect(filter.search == "nostr")
        #expect(filter.kinds == [1])
        #expect(filter.limit == 20)
    }

    @Test("Tag subscript sets, reads, and removes a generic tag query")
    func tagSubscriptSetsReadsAndRemoves() {
        var filter = Filter(kinds: [1])
        filter[tag: .hashtag] = ["nostr", "bitcoin"]

        #expect(filter[tag: .hashtag] == ["nostr", "bitcoin"])
        #expect(filter[tag: "t"] == ["nostr", "bitcoin"])
        #expect(filter[tag: "r"] == nil)

        filter[tag: .hashtag] = ["nostr"]
        #expect(filter[tag: .hashtag] == ["nostr"])

        filter[tag: .hashtag] = nil
        #expect(filter[tag: .hashtag] == nil)
        #expect(filter == Filter(kinds: [1]))
    }

    /// The name is the tag name; `#` is wire syntax, so `"#t"` names a different tag than `"t"`.
    @Test("Tag subscript takes the name without the wire #")
    func tagSubscriptNameIsTheTagName() {
        var filter = Filter(kinds: [1])
        filter[tag: .hashtag] = ["nostr"]

        #expect(filter[tag: "#t"] == nil)
    }

    @Test("Tag subscript on e and p is the same query as the typed references")
    func tagSubscriptSharesEventAndPublicKeyReferences() {
        var filter = Filter(kinds: [1])
        filter[tag: .event] = [note.hex]
        filter[tag: .publicKey] = [alice.hex]

        #expect(filter.eventReferences == [note])
        #expect(filter.publicKeyReferences == [alice])

        filter.eventReferences = [reply]
        filter.publicKeyReferences = [bob]

        #expect(filter[tag: .event] == [reply.hex])
        #expect(filter[tag: .publicKey] == [bob.hex])

        filter[tag: .event] = nil
        filter.publicKeyReferences = nil

        #expect(filter.eventReferences == nil)
        #expect(filter[tag: .publicKey] == nil)
    }

    /// Values assigned through the subscript are never dropped: the query keeps and encodes them as
    /// given, and only the typed view leaves out what it cannot represent.
    @Test("Non-canonical e and p values set through the tag subscript are kept and encoded")
    func tagSubscriptKeepsNonCanonicalReferences() throws {
        var filter = Filter(kinds: [1])
        filter[tag: .event] = [note.hex, "not-an-id"]
        filter[tag: .publicKey] = [alice.hex.uppercased()]

        #expect(filter[tag: .event] == [note.hex, "not-an-id"])
        #expect(filter[tag: .publicKey] == [alice.hex.uppercased()])
        #expect(filter.eventReferences == [note])
        #expect(filter.publicKeyReferences == [])

        let data = try JSONEncoder().encode(filter)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["#e"] as? [String] == [note.hex, "not-an-id"])
        #expect(json["#p"] as? [String] == [alice.hex.uppercased()])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Filter.self, from: data)
        }
    }

    @Test("Filter JSON round-trips every tag query, e and p included")
    func filterJSONRoundTripsTagQueries() throws {
        let json = """
            {
                "kinds": [30023],
                "#t": ["nostr"],
                "#e": ["\(note.hex)", "\(reply.hex)"],
                "#p": ["\(alice.hex)"],
                "#d": ["essay"]
            }
            """

        let decoded = try JSONDecoder().decode(Filter.self, from: Data(json.utf8))
        let reencoded = try JSONEncoder().encode(decoded)
        let redecoded = try JSONDecoder().decode(Filter.self, from: reencoded)

        #expect(redecoded == decoded)
        #expect(redecoded[tag: .hashtag] == ["nostr"])
        #expect(redecoded[tag: .identifier] == ["essay"])
        #expect(redecoded[tag: .event] == [note.hex, reply.hex])
        #expect(redecoded.eventReferences == [note, reply])
        #expect(redecoded.publicKeyReferences == [alice])
        let object = try #require(JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect(Set(object.keys) == ["kinds", "#t", "#e", "#p", "#d"])
    }
}
