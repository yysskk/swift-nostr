import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Relay List Metadata Tests (NIP-65)")
struct RelayListMetadataTests {

    // MARK: - Usage flags

    @Test("Usage read/write flags")
    func usageFlags() {
        #expect(RelayUsage.read.canRead == true)
        #expect(RelayUsage.read.canWrite == false)
        #expect(RelayUsage.write.canRead == false)
        #expect(RelayUsage.write.canWrite == true)
        #expect(RelayUsage.readWrite.canRead == true)
        #expect(RelayUsage.readWrite.canWrite == true)
    }

    // MARK: - Entry tag

    @Test("Entry tag - read+write (no marker)")
    func entryTagReadWrite() {
        let entry = RelayListEntry(url: RelayURL("wss://relay.example.com")!, usage: .readWrite)
        #expect(entry.tag.rawArray == ["r", "wss://relay.example.com"])
    }

    @Test("Entry tag - read only")
    func entryTagRead() {
        let entry = RelayListEntry(url: RelayURL("wss://relay.example.com")!, usage: .read)
        #expect(entry.tag.rawArray == ["r", "wss://relay.example.com", "read"])
    }

    @Test("Entry tag - write only")
    func entryTagWrite() {
        let entry = RelayListEntry(url: RelayURL("wss://relay.example.com")!, usage: .write)
        #expect(entry.tag.rawArray == ["r", "wss://relay.example.com", "write"])
    }

    @Test("Entry default usage is read+write")
    func entryDefaultUsage() {
        let entry = RelayListEntry(url: RelayURL("wss://relay.example.com")!)
        #expect(entry.usage == .readWrite)
    }

    // MARK: - Entry init(tag:)

    @Test("Entry init(tag:) - no marker means read+write")
    func entryInitTagNoMarker() {
        let entry = RelayListEntry(tag: Event.Tag(rawArray: ["r", "wss://relay.example.com"]))
        #expect(entry?.url == RelayURL("wss://relay.example.com"))
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry init(tag:) - read marker")
    func entryInitTagRead() {
        let entry = RelayListEntry(tag: Event.Tag(rawArray: ["r", "wss://relay.example.com", "read"]))
        #expect(entry?.usage == .read)
    }

    @Test("Entry init(tag:) - write marker")
    func entryInitTagWrite() {
        let entry = RelayListEntry(tag: Event.Tag(rawArray: ["r", "wss://relay.example.com", "write"]))
        #expect(entry?.usage == .write)
    }

    @Test("Entry init(tag:) - empty marker means read+write")
    func entryInitTagEmptyMarker() {
        let entry = RelayListEntry(tag: Event.Tag(rawArray: ["r", "wss://relay.example.com", ""]))
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry init(tag:) - unknown marker is lenient read+write")
    func entryInitTagUnknownMarker() {
        let entry = RelayListEntry(tag: Event.Tag(rawArray: ["r", "wss://relay.example.com", "garbage"]))
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry init(tag:) - missing url returns nil")
    func entryInitTagMissingURL() {
        #expect(RelayListEntry(tag: Event.Tag(rawArray: ["r"])) == nil)
        #expect(RelayListEntry(tag: Event.Tag(rawArray: ["r", ""])) == nil)
    }

    @Test("Entry init(tag:) - wrong tag type returns nil")
    func entryInitTagWrongType() {
        #expect(RelayListEntry(tag: Event.Tag(rawArray: ["p", "wss://relay.example.com"])) == nil)
    }

    @Test("Entry round-trips through tag and init(tag:)", arguments: [RelayUsage.readWrite, .read, .write])
    func entryTagRoundTrip(usage: RelayUsage) throws {
        let entry = RelayListEntry(url: try #require(RelayURL("wss://relay.example.com")), usage: usage)
        #expect(RelayListEntry(tag: entry.tag) == entry)
    }

    // MARK: - Metadata read/write filtering

    @Test("readRelays and writeRelays filtering")
    func readWriteFiltering() {
        let list = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://both.example.com")!, usage: .readWrite),
            RelayListEntry(url: RelayURL("wss://read.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://write.example.com")!, usage: .write),
        ])

        #expect(list.readRelays == [RelayURL("wss://both.example.com")!, RelayURL("wss://read.example.com")!])
        #expect(list.writeRelays == [RelayURL("wss://both.example.com")!, RelayURL("wss://write.example.com")!])
    }

    // MARK: - tags / parse round-trip

    @Test("tags produces NIP-65 r tags")
    func tagsFormat() {
        let list = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://a.example.com")!, usage: .readWrite),
            RelayListEntry(url: RelayURL("wss://b.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://c.example.com")!, usage: .write),
        ])

        #expect(
            list.tags.map(\.rawArray) == [
                ["r", "wss://a.example.com"],
                ["r", "wss://b.example.com", "read"],
                ["r", "wss://c.example.com", "write"],
            ]
        )
    }

    @Test("Round-trip tags then init(tags:)")
    func roundTrip() {
        let original = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://a.example.com")!, usage: .readWrite),
            RelayListEntry(url: RelayURL("wss://b.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://c.example.com")!, usage: .write),
        ])

        let parsed = RelayListMetadata(tags: original.tags)
        #expect(parsed.entries == original.entries)
    }

    @Test("Parsing ignores non-r tags")
    func parsingIgnoresOtherTags() {
        let list = RelayListMetadata(
            tags: [
                ["r", "wss://a.example.com"],
                ["p", "somepublickey"],
                ["r", "wss://b.example.com", "read"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.entries.count == 2)
        #expect(list.entries[0].url == RelayURL("wss://a.example.com"))
        #expect(list.entries[1].url == RelayURL("wss://b.example.com"))
    }

    @Test("Duplicate relay URLs are de-duplicated (first wins)")
    func duplicateURLs() {
        let list = RelayListMetadata(
            tags: [
                ["r", "wss://a.example.com", "read"],
                ["r", "wss://a.example.com", "write"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.entries.count == 1)
        #expect(list.entries[0].usage == .read)
    }

    @Test("Trailing slash duplicates collapse")
    func trailingSlashDedup() {
        let list = RelayListMetadata(
            tags: [
                ["r", "wss://a.example.com"],
                ["r", "wss://a.example.com/"],
            ].map(Event.Tag.init(rawArray:)))
        #expect(list.entries.count == 1)
    }

    @Test("A parsed relay is written back in canonical form")
    func parsedURLIsCanonical() {
        let list = RelayListMetadata(tags: [.reference(URL(string: "wss://Relay.Example.com/")!)])
        #expect(list.entries.count == 1)
        #expect(list.entries[0].url == RelayURL("wss://relay.example.com"))
        #expect(list.tags.map(\.rawArray) == [["r", "wss://relay.example.com"]])
    }

    @Test(
        "An r tag whose URL is not a relay URL is skipped",
        arguments: ["https://relay.example.com", "not a relay", "wss://relay.example.com/#frag"])
    func malformedURLIsSkipped(url: String) {
        #expect(RelayListEntry(tag: Event.Tag(rawArray: ["r", url])) == nil)
        let list = RelayListMetadata(tags: [
            Event.Tag(rawArray: ["r", url]), Event.Tag(name: .reference, values: ["wss://good.example.com", "write"]),
        ])
        #expect(list.entries == [RelayListEntry(url: RelayURL("wss://good.example.com")!, usage: .write)])
    }
}

@Suite("Relay List Metadata Event Tests (NIP-65)")
struct RelayListMetadataEventTests {

    @Test("Sign relay list metadata event")
    func signRelayListEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://a.example.com")!, usage: .readWrite),
            RelayListEntry(url: RelayURL("wss://b.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://c.example.com")!, usage: .write),
        ])

        let event = signer.sign(.relayListMetadata(list))

        #expect(event.kind == 10002)
        #expect(event.content == "")
        #expect(event.tags == list.tags)
        try event.verify()
    }

    @Test("Sign relay list from read/write URLs")
    func signRelayListFromReadWrite() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let relayList = RelayListMetadata(
            read: [RelayURL("wss://read.example.com")!, RelayURL("wss://both.example.com")!],
            write: [RelayURL("wss://write.example.com")!, RelayURL("wss://both.example.com")!]
        )
        let event = signer.sign(.relayListMetadata(relayList))

        #expect(event.kind == 10002)
        let list = event.relayListMetadata
        #expect(list != nil)
        // Order is not guaranteed for the read/write overload; compare as sets.
        #expect(
            Set(list?.readRelays ?? []) == [RelayURL("wss://read.example.com")!, RelayURL("wss://both.example.com")!])
        #expect(
            Set(list?.writeRelays ?? []) == [RelayURL("wss://write.example.com")!, RelayURL("wss://both.example.com")!])
    }

    @Test("Sign relay list from read/write URLs collapses repeated URLs into one entry")
    func signRelayListFromReadWriteDeduplicates() throws {
        let signer = EventSigner(keyPair: KeyPair())

        let relayList = RelayListMetadata(
            read: [RelayURL("wss://a.example.com")!, RelayURL("wss://a.example.com/")!],
            write: [RelayURL("wss://b.example.com")!, RelayURL("wss://B.example.com")!]
        )
        let event = signer.sign(.relayListMetadata(relayList))

        // Repeats — including alternate spellings of the same relay — must not become
        // duplicate `r` tags, matching how a parsed list de-duplicates.
        #expect(event.tags.count == 2)
        let list = event.relayListMetadata
        #expect(list?.readRelays == [RelayURL("wss://a.example.com")!])
        #expect(list?.writeRelays == [RelayURL("wss://b.example.com")!])
    }

    @Test("A relay spelled differently in read and write is still marked read+write")
    func signRelayListMergesEquivalentReadAndWriteSpellings() throws {
        let signer = EventSigner(keyPair: KeyPair())

        // The same relay, spelled with a trailing slash on one side and mixed case on the other.
        // Both usages must survive: dropping one would silently demote the relay.
        let event = signer.sign(
            .relayListMetadata(
                RelayListMetadata(
                    read: [RelayURL("wss://Relay.example.com/")!], write: [RelayURL("wss://relay.example.com")!]))
        )

        #expect(event.tags.map(\.rawArray) == [["r", "wss://relay.example.com"]])
        let list = try #require(event.relayListMetadata)
        #expect(list.entries.count == 1)
        #expect(list.entries[0].usage == .readWrite)
        #expect(list.readRelays == [RelayURL("wss://relay.example.com")!])
        #expect(list.writeRelays == [RelayURL("wss://relay.example.com")!])
    }

    @Test("Extract relay list from event")
    func extractRelayListFromEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://a.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://b.example.com")!, usage: .write),
        ])
        let event = signer.sign(.relayListMetadata(list))

        let extracted = event.relayListMetadata
        #expect(extracted != nil)
        #expect(extracted?.entries.count == 2)
        #expect(extracted?.readRelays == [RelayURL("wss://a.example.com")!])
        #expect(extracted?.writeRelays == [RelayURL("wss://b.example.com")!])
    }

    @Test("relayListMetadata returns nil for non-10002 event")
    func relayListNilForOtherKind() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = signer.sign(.textNote("Hello"))
        #expect(textNote.relayListMetadata == nil)
        #expect(textNote.isRelayListMetadata == false)
    }

    @Test("isRelayListMetadata property")
    func isRelayListMetadataProperty() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let relayListEvent = signer.sign(
            .relayListMetadata(RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://a.example.com")!)]))
        )
        let textNote = signer.sign(.textNote("Hello"))

        #expect(relayListEvent.isRelayListMetadata == true)
        #expect(textNote.isRelayListMetadata == false)
    }
}

@Suite("Relay List Metadata Filter Tests (NIP-65)")
struct RelayListMetadataFilterTests {

    @Test("Relay list filter for single public key")
    func filterSinglePublicKey() {
        let filter = Filter.relayListMetadata(publicKey: .fixture("abc123"))
        #expect(filter.authors == [.fixture("abc123")])
        #expect(filter.kinds == [10002])
        #expect(filter.limit == 1)
    }

    @Test("Relay list filter for multiple public keys")
    func filterMultiplePublicKeys() {
        let filter = Filter.relayListMetadata(publicKeys: [.fixture("abc123"), .fixture("def456")])
        #expect(filter.authors == [.fixture("abc123"), .fixture("def456")])
        #expect(filter.kinds == [10002])
        #expect(filter.limit == nil)
    }
}
