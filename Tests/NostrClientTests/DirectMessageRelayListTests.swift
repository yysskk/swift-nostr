import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Direct Message Relay List Tests (NIP-17, kind 10050)")
struct DirectMessageRelayListTests {

    // MARK: - tags / parse round-trip

    @Test("tags produces NIP-17 relay tags")
    func tagsFormat() {
        let list = DirectMessageRelayList(relays: [
            RelayURL("wss://inbox.example.com")!,
            RelayURL("wss://dm.example.com")!,
        ])

        #expect(
            list.tags.map(\.rawArray) == [
                ["relay", "wss://inbox.example.com"],
                ["relay", "wss://dm.example.com"],
            ]
        )
    }

    @Test("Round-trip tags then init(tags:)")
    func roundTrip() {
        let original = DirectMessageRelayList(relays: [
            RelayURL("wss://a.example.com")!,
            RelayURL("wss://b.example.com")!,
        ])

        let parsed = DirectMessageRelayList(tags: original.tags)
        #expect(parsed.relays == original.relays)
    }

    @Test("Parsing ignores non-relay tags")
    func parsingIgnoresOtherTags() {
        let list = DirectMessageRelayList(
            tags: [
                ["relay", "wss://a.example.com"],
                ["r", "wss://b.example.com"],
                ["p", "somepublickey"],
                ["relay", "wss://c.example.com"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.relays == [RelayURL("wss://a.example.com")!, RelayURL("wss://c.example.com")!])
    }

    @Test("Empty or missing relay URL is skipped")
    func parsingSkipsEmptyURL() {
        let list = DirectMessageRelayList(
            tags: [
                ["relay"],
                ["relay", ""],
                ["relay", "wss://a.example.com"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.relays == [RelayURL("wss://a.example.com")!])
    }

    @Test("Duplicate relay URLs are de-duplicated (first wins)")
    func duplicateURLs() {
        let list = DirectMessageRelayList(
            tags: [
                ["relay", "wss://a.example.com"],
                ["relay", "wss://a.example.com"],
                ["relay", "wss://b.example.com"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.relays == [RelayURL("wss://a.example.com")!, RelayURL("wss://b.example.com")!])
    }

    @Test("Trailing slash and case duplicates collapse")
    func trailingSlashDedup() {
        let list = DirectMessageRelayList(
            tags: [
                ["relay", "wss://a.example.com"],
                ["relay", "wss://a.example.com/"],
                ["relay", "wss://A.EXAMPLE.com"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.relays == [RelayURL("wss://a.example.com")!])
    }

    @Test("init(relays:) de-duplicates like parsing")
    func initRelaysDeduplicates() {
        let list = DirectMessageRelayList(relays: [
            RelayURL("wss://a.example.com")!,
            RelayURL("wss://A.example.com/")!,
            RelayURL("wss://b.example.com")!,
        ])
        #expect(list.relays == [RelayURL("wss://a.example.com")!, RelayURL("wss://b.example.com")!])
    }

    @Test("Signing a list with duplicates round-trips through the event")
    func signedListRoundTripsWithDuplicates() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!, RelayURL("wss://a.example.com/")!])
        let event = signer.sign(.directMessageRelayList(list))
        // The signed event's tags and the re-parsed list agree — no dangling duplicate tags.
        #expect(event.tags.map(\.rawArray) == [["relay", "wss://a.example.com"]])
        #expect(event.directMessageRelayList?.relays == [RelayURL("wss://a.example.com")!])
    }

    @Test("A parsed relay is written back in canonical form")
    func parsedURLIsCanonical() {
        let list = DirectMessageRelayList(tags: [Event.Tag(name: .relay, values: ["wss://Inbox.Example.com/"])])
        #expect(list.relays == [RelayURL("wss://inbox.example.com")!])
        #expect(list.tags.map(\.rawArray) == [["relay", "wss://inbox.example.com"]])
    }

    @Test("A relay tag whose URL is not a relay URL is skipped")
    func parsingSkipsMalformedURL() {
        let list = DirectMessageRelayList(
            tags: [
                ["relay", "https://inbox.example.com"],
                ["relay", "not a relay"],
                ["relay", "wss://a.example.com"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.relays == [RelayURL("wss://a.example.com")!])
    }

    // MARK: - Event signing & extraction

    @Test("Sign DM relay list event")
    func signEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = DirectMessageRelayList(relays: [
            RelayURL("wss://inbox.example.com")!,
            RelayURL("wss://dm.example.com")!,
        ])
        let event = signer.sign(.directMessageRelayList(list))

        #expect(event.kind == 10050)
        #expect(event.content == "")
        #expect(event.tags == list.tags)
        try event.verify()
    }

    @Test("Sign DM relay list from relay URLs")
    func signFromRelays() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = signer.sign(
            .directMessageRelayList(DirectMessageRelayList(relays: [RelayURL("wss://inbox.example.com")!])))

        #expect(event.kind == 10050)
        #expect(event.directMessageRelayList?.relays == [RelayURL("wss://inbox.example.com")!])
    }

    @Test("Extract DM relay list from event")
    func extractFromEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!, RelayURL("wss://b.example.com")!])
        let event = signer.sign(.directMessageRelayList(list))

        let extracted = event.directMessageRelayList
        #expect(extracted?.relays == [RelayURL("wss://a.example.com")!, RelayURL("wss://b.example.com")!])
    }

    @Test("directMessageRelayList returns nil for non-10050 event")
    func nilForOtherKind() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = signer.sign(.textNote("Hello"))
        #expect(textNote.directMessageRelayList == nil)
        #expect(textNote.isDirectMessageRelayList == false)
    }

    @Test("isDirectMessageRelayList property")
    func isDirectMessageRelayListProperty() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let dmRelayEvent = signer.sign(
            .directMessageRelayList(DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!])))
        let textNote = signer.sign(.textNote("Hello"))

        #expect(dmRelayEvent.isDirectMessageRelayList == true)
        #expect(textNote.isDirectMessageRelayList == false)
    }
}

@Suite("Direct Message Relay List Filter Tests (NIP-17)")
struct DirectMessageRelayListFilterTests {

    @Test("DM relay list filter for single public key")
    func filterSinglePublicKey() {
        let filter = Filter.directMessageRelayList(publicKey: .fixture("abc123"))
        #expect(filter.authors == [.fixture("abc123")])
        #expect(filter.kinds == [10050])
        #expect(filter.limit == 1)
    }

    @Test("DM relay list filter for multiple public keys")
    func filterMultiplePublicKeys() {
        let filter = Filter.directMessageRelayList(publicKeys: [.fixture("abc123"), .fixture("def456")])
        #expect(filter.authors == [.fixture("abc123"), .fixture("def456")])
        #expect(filter.kinds == [10050])
        #expect(filter.limit == nil)
    }
}
