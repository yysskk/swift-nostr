import Foundation
import NostrCore
import Testing

@Suite("Filter Tests")
struct FilterTests {

    @Test("Create basic filter")
    func createBasicFilter() {
        let filter = Filter(
            authors: ["pubkey1", "pubkey2"],
            kinds: [1],
            limit: 50
        )

        #expect(filter.authors == ["pubkey1", "pubkey2"])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 50)
    }

    @Test("Filter with event references")
    func filterWithEventReferences() {
        let filter = Filter(
            kinds: [1],
            eventReferences: ["eventid1", "eventid2"]
        )

        #expect(filter.eventReferences == ["eventid1", "eventid2"])
    }

    @Test("Filter with pubkey references")
    func filterWithPubkeyReferences() {
        let filter = Filter(
            kinds: [1],
            pubkeyReferences: ["pubkey1"]
        )

        #expect(filter.pubkeyReferences == ["pubkey1"])
    }

    @Test("Filter with time range")
    func filterWithTimeRange() {
        let now = Int64(Date().timeIntervalSince1970)
        let filter = Filter(
            since: now - 3600,
            until: now
        )

        #expect(filter.since == now - 3600)
        #expect(filter.until == now)
    }

    @Test("User notes convenience filter")
    func userNotesFilter() {
        let pubkey = "testpubkey123"
        let filter = Filter.userNotes(pubkey: pubkey, limit: 25)

        #expect(filter.authors == [pubkey])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 25)
    }

    @Test("Metadata convenience filter")
    func metadataFilter() {
        let pubkeys = ["pubkey1", "pubkey2"]
        let filter = Filter.metadata(pubkeys: pubkeys)

        #expect(filter.authors == pubkeys)
        #expect(filter.kinds == [0])
    }

    @Test("Replies convenience filter")
    func repliesFilter() {
        let eventId = "eventid123"
        let filter = Filter.replies(to: eventId, limit: 50)

        #expect(filter.eventReferences == [eventId])
        #expect(filter.kinds == [1])
        #expect(filter.limit == 50)
    }

    @Test("Mentions convenience filter")
    func mentionsFilter() {
        let pubkey = "testpubkey"
        let filter = Filter.mentions(pubkey: pubkey)

        #expect(filter.pubkeyReferences == [pubkey])
        #expect(filter.kinds == [1])
    }

    @Test("Global feed convenience filter")
    func globalFeedFilter() {
        let filter = Filter.globalFeed(limit: 100)

        #expect(filter.kinds == [1])
        #expect(filter.limit == 100)
    }

    @Test("Filter JSON encoding")
    func filterJsonEncoding() throws {
        let filter = Filter(
            authors: ["pubkey1"],
            kinds: [1],
            eventReferences: ["eventid1"],
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
    func filterJsonDecoding() throws {
        let json = """
            {
                "authors": ["pubkey1"],
                "kinds": [1, 7],
                "#e": ["eventid1"],
                "#p": ["pubkey2"],
                "limit": 50
            }
            """

        let decoder = JSONDecoder()
        let filter = try decoder.decode(Filter.self, from: json.data(using: .utf8)!)

        #expect(filter.authors == ["pubkey1"])
        #expect(filter.kinds == [1, 7])
        #expect(filter.eventReferences == ["eventid1"])
        #expect(filter.pubkeyReferences == ["pubkey2"])
        #expect(filter.limit == 50)
    }

    @Test("Filter with generic tag query")
    func filterWithGenericTagQuery() {
        var filter = Filter(kinds: [1])
        filter.addTagQuery("t", values: ["nostr", "bitcoin"])

        #expect(filter.getTagQuery("t") == ["nostr", "bitcoin"])
        #expect(filter.getTagQuery("#t") == ["nostr", "bitcoin"])
    }
}
