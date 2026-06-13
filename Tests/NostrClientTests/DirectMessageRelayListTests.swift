import Foundation
import Testing

@testable import NostrClient

@Suite("Direct Message Relay List Tests (NIP-17, kind 10050)")
struct DirectMessageRelayListTests {

    // MARK: - toTags / parse round-trip

    @Test("toTags produces NIP-17 relay tags")
    func toTagsFormat() {
        let list = DirectMessageRelayList(relays: [
            "wss://inbox.example.com",
            "wss://dm.example.com",
        ])

        #expect(
            list.toTags() == [
                ["relay", "wss://inbox.example.com"],
                ["relay", "wss://dm.example.com"],
            ]
        )
    }

    @Test("Round-trip toTags then init(tags:)")
    func roundTrip() {
        let original = DirectMessageRelayList(relays: [
            "wss://a.example.com",
            "wss://b.example.com",
        ])

        let parsed = DirectMessageRelayList(tags: original.toTags())
        #expect(parsed.relays == original.relays)
    }

    @Test("Parsing ignores non-relay tags")
    func parsingIgnoresOtherTags() {
        let list = DirectMessageRelayList(tags: [
            ["relay", "wss://a.example.com"],
            ["r", "wss://b.example.com"],
            ["p", "somepubkey"],
            ["relay", "wss://c.example.com"],
        ])
        #expect(list.relays == ["wss://a.example.com", "wss://c.example.com"])
    }

    @Test("Empty or missing relay URL is skipped")
    func parsingSkipsEmptyURL() {
        let list = DirectMessageRelayList(tags: [
            ["relay"],
            ["relay", ""],
            ["relay", "wss://a.example.com"],
        ])
        #expect(list.relays == ["wss://a.example.com"])
    }

    @Test("Duplicate relay URLs are de-duplicated (first wins)")
    func duplicateURLs() {
        let list = DirectMessageRelayList(tags: [
            ["relay", "wss://a.example.com"],
            ["relay", "wss://a.example.com"],
            ["relay", "wss://b.example.com"],
        ])
        #expect(list.relays == ["wss://a.example.com", "wss://b.example.com"])
    }

    @Test("Trailing slash and case duplicates collapse")
    func trailingSlashDedup() {
        let list = DirectMessageRelayList(tags: [
            ["relay", "wss://a.example.com"],
            ["relay", "wss://a.example.com/"],
            ["relay", "wss://A.EXAMPLE.com"],
        ])
        #expect(list.relays == ["wss://a.example.com"])
    }

    @Test("init(relays:) de-duplicates like parsing")
    func initRelaysDeduplicates() {
        let list = DirectMessageRelayList(relays: [
            "wss://a.example.com",
            "wss://A.example.com/",
            "wss://b.example.com",
        ])
        #expect(list.relays == ["wss://a.example.com", "wss://b.example.com"])
    }

    @Test("Signing a list with duplicates round-trips through the event")
    func signedListRoundTripsWithDuplicates() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signDirectMessageRelayList(relays: [
            "wss://a.example.com",
            "wss://a.example.com/",
        ])
        // The signed event's tags and the re-parsed list agree — no dangling duplicate tags.
        #expect(event.tags == [["relay", "wss://a.example.com"]])
        #expect(event.directMessageRelayList?.relays == ["wss://a.example.com"])
    }

    @Test("Stored url is not mutated by normalization")
    func storedURLNotMutated() {
        // A mixed-case host with a trailing slash must round-trip exactly through toTags().
        let list = DirectMessageRelayList(tags: [["relay", "wss://Inbox.Example.com/"]])
        #expect(list.relays == ["wss://Inbox.Example.com/"])
        #expect(list.toTags() == [["relay", "wss://Inbox.Example.com/"]])
    }

    // MARK: - Event signing & extraction

    @Test("Sign DM relay list event")
    func signEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = DirectMessageRelayList(relays: [
            "wss://inbox.example.com",
            "wss://dm.example.com",
        ])
        let event = try signer.signDirectMessageRelayList(list)

        #expect(event.kind == 10050)
        #expect(event.content == "")
        #expect(event.tags == list.toTags())
        #expect(try event.verify())
    }

    @Test("Sign DM relay list from relay URLs")
    func signFromRelays() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signDirectMessageRelayList(relays: ["wss://inbox.example.com"])

        #expect(event.kind == 10050)
        #expect(event.directMessageRelayList?.relays == ["wss://inbox.example.com"])
    }

    @Test("Extract DM relay list from event")
    func extractFromEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = DirectMessageRelayList(relays: ["wss://a.example.com", "wss://b.example.com"])
        let event = try signer.signDirectMessageRelayList(list)

        let extracted = event.directMessageRelayList
        #expect(extracted?.relays == ["wss://a.example.com", "wss://b.example.com"])
    }

    @Test("directMessageRelayList returns nil for non-10050 event")
    func nilForOtherKind() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = try signer.signTextNote(content: "Hello")
        #expect(textNote.directMessageRelayList == nil)
        #expect(textNote.isDirectMessageRelayList == false)
    }

    @Test("isDirectMessageRelayList property")
    func isDirectMessageRelayListProperty() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let dmRelayEvent = try signer.signDirectMessageRelayList(relays: ["wss://a.example.com"])
        let textNote = try signer.signTextNote(content: "Hello")

        #expect(dmRelayEvent.isDirectMessageRelayList == true)
        #expect(textNote.isDirectMessageRelayList == false)
    }
}

@Suite("Direct Message Relay List Filter Tests (NIP-17)")
struct DirectMessageRelayListFilterTests {

    @Test("DM relay list filter for single pubkey")
    func filterSinglePubkey() {
        let filter = Filter.directMessageRelayList(pubkey: "abc123")
        #expect(filter.authors == ["abc123"])
        #expect(filter.kinds == [10050])
        #expect(filter.limit == 1)
    }

    @Test("DM relay list filter for multiple pubkeys")
    func filterMultiplePubkeys() {
        let filter = Filter.directMessageRelayList(pubkeys: ["abc123", "def456"])
        #expect(filter.authors == ["abc123", "def456"])
        #expect(filter.kinds == [10050])
        #expect(filter.limit == nil)
    }
}

@Suite("Relay URL Normalization Tests")
struct RelayURLTests {

    @Test("Lowercases the URL")
    func lowercases() {
        #expect(RelayURL.normalize("wss://Relay.Example.COM") == "wss://relay.example.com")
    }

    @Test("Strips a single trailing slash")
    func stripsTrailingSlash() {
        #expect(RelayURL.normalize("wss://relay.example.com/") == "wss://relay.example.com")
    }

    @Test("Leaves a URL without a trailing slash unchanged")
    func noTrailingSlash() {
        #expect(RelayURL.normalize("wss://relay.example.com") == "wss://relay.example.com")
    }
}
