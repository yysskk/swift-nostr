import Foundation
import NostrCore
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

    // MARK: - Entry to tag

    @Test("Entry to tag - read+write (no marker)")
    func entryToTagReadWrite() {
        let entry = RelayListEntry(url: "wss://relay.example.com", usage: .readWrite)
        #expect(entry.toTag() == ["r", "wss://relay.example.com"])
    }

    @Test("Entry to tag - read only")
    func entryToTagRead() {
        let entry = RelayListEntry(url: "wss://relay.example.com", usage: .read)
        #expect(entry.toTag() == ["r", "wss://relay.example.com", "read"])
    }

    @Test("Entry to tag - write only")
    func entryToTagWrite() {
        let entry = RelayListEntry(url: "wss://relay.example.com", usage: .write)
        #expect(entry.toTag() == ["r", "wss://relay.example.com", "write"])
    }

    @Test("Entry default usage is read+write")
    func entryDefaultUsage() {
        let entry = RelayListEntry(url: "wss://relay.example.com")
        #expect(entry.usage == .readWrite)
    }

    // MARK: - Entry from tag

    @Test("Entry from tag - no marker means read+write")
    func entryFromTagNoMarker() {
        let entry = RelayListEntry.fromTag(["r", "wss://relay.example.com"])
        #expect(entry?.url == "wss://relay.example.com")
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry from tag - read marker")
    func entryFromTagRead() {
        let entry = RelayListEntry.fromTag(["r", "wss://relay.example.com", "read"])
        #expect(entry?.usage == .read)
    }

    @Test("Entry from tag - write marker")
    func entryFromTagWrite() {
        let entry = RelayListEntry.fromTag(["r", "wss://relay.example.com", "write"])
        #expect(entry?.usage == .write)
    }

    @Test("Entry from tag - empty marker means read+write")
    func entryFromTagEmptyMarker() {
        let entry = RelayListEntry.fromTag(["r", "wss://relay.example.com", ""])
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry from tag - unknown marker is lenient read+write")
    func entryFromTagUnknownMarker() {
        let entry = RelayListEntry.fromTag(["r", "wss://relay.example.com", "garbage"])
        #expect(entry?.usage == .readWrite)
    }

    @Test("Entry from tag - missing url returns nil")
    func entryFromTagMissingURL() {
        #expect(RelayListEntry.fromTag(["r"]) == nil)
        #expect(RelayListEntry.fromTag(["r", ""]) == nil)
    }

    @Test("Entry from tag - wrong tag type returns nil")
    func entryFromTagWrongType() {
        #expect(RelayListEntry.fromTag(["p", "wss://relay.example.com"]) == nil)
    }

    // MARK: - Metadata read/write filtering

    @Test("readRelays and writeRelays filtering")
    func readWriteFiltering() {
        let list = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://both.example.com", usage: .readWrite),
            RelayListEntry(url: "wss://read.example.com", usage: .read),
            RelayListEntry(url: "wss://write.example.com", usage: .write),
        ])

        #expect(list.readRelays == ["wss://both.example.com", "wss://read.example.com"])
        #expect(list.writeRelays == ["wss://both.example.com", "wss://write.example.com"])
    }

    // MARK: - toTags / parse round-trip

    @Test("toTags produces NIP-65 r tags")
    func toTagsFormat() {
        let list = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://a.example.com", usage: .readWrite),
            RelayListEntry(url: "wss://b.example.com", usage: .read),
            RelayListEntry(url: "wss://c.example.com", usage: .write),
        ])

        #expect(
            list.toTags() == [
                ["r", "wss://a.example.com"],
                ["r", "wss://b.example.com", "read"],
                ["r", "wss://c.example.com", "write"],
            ]
        )
    }

    @Test("Round-trip toTags then init(tags:)")
    func roundTrip() {
        let original = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://a.example.com", usage: .readWrite),
            RelayListEntry(url: "wss://b.example.com", usage: .read),
            RelayListEntry(url: "wss://c.example.com", usage: .write),
        ])

        let parsed = RelayListMetadata(tags: original.toTags())
        #expect(parsed.entries == original.entries)
    }

    @Test("Parsing ignores non-r tags")
    func parsingIgnoresOtherTags() {
        let list = RelayListMetadata(tags: [
            ["r", "wss://a.example.com"],
            ["p", "somepubkey"],
            ["r", "wss://b.example.com", "read"],
        ])
        #expect(list.entries.count == 2)
        #expect(list.entries[0].url == "wss://a.example.com")
        #expect(list.entries[1].url == "wss://b.example.com")
    }

    @Test("Duplicate relay URLs are de-duplicated (first wins)")
    func duplicateURLs() {
        let list = RelayListMetadata(tags: [
            ["r", "wss://a.example.com", "read"],
            ["r", "wss://a.example.com", "write"],
        ])
        #expect(list.entries.count == 1)
        #expect(list.entries[0].usage == .read)
    }

    @Test("Trailing slash duplicates collapse")
    func trailingSlashDedup() {
        let list = RelayListMetadata(tags: [
            ["r", "wss://a.example.com"],
            ["r", "wss://a.example.com/"],
        ])
        #expect(list.entries.count == 1)
    }

    @Test("Stored url is not mutated by normalization")
    func storedURLNotMutated() {
        // A mixed-case host with a trailing slash must round-trip exactly through toTags().
        let list = RelayListMetadata(tags: [["r", "wss://Relay.Example.com/"]])
        #expect(list.entries.count == 1)
        #expect(list.entries[0].url == "wss://Relay.Example.com/")
        #expect(list.toTags() == [["r", "wss://Relay.Example.com/"]])
    }
}

@Suite("Relay List Metadata Event Tests (NIP-65)")
struct RelayListMetadataEventTests {

    @Test("Sign relay list metadata event")
    func signRelayListEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://a.example.com", usage: .readWrite),
            RelayListEntry(url: "wss://b.example.com", usage: .read),
            RelayListEntry(url: "wss://c.example.com", usage: .write),
        ])

        let event = try signer.signRelayListMetadata(list)

        #expect(event.kind == 10002)
        #expect(event.content == "")
        #expect(event.tags == list.toTags())
        #expect(try event.verify())
    }

    @Test("Sign relay list from read/write URLs")
    func signRelayListFromReadWrite() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signRelayListMetadata(
            read: ["wss://read.example.com", "wss://both.example.com"],
            write: ["wss://write.example.com", "wss://both.example.com"]
        )

        #expect(event.kind == 10002)
        let list = event.relayListMetadata
        #expect(list != nil)
        // Order is not guaranteed for the read/write overload; compare as sets.
        #expect(Set(list?.readRelays ?? []) == ["wss://read.example.com", "wss://both.example.com"])
        #expect(Set(list?.writeRelays ?? []) == ["wss://write.example.com", "wss://both.example.com"])
    }

    @Test("Extract relay list from event")
    func extractRelayListFromEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://a.example.com", usage: .read),
            RelayListEntry(url: "wss://b.example.com", usage: .write),
        ])
        let event = try signer.signRelayListMetadata(list)

        let extracted = event.relayListMetadata
        #expect(extracted != nil)
        #expect(extracted?.entries.count == 2)
        #expect(extracted?.readRelays == ["wss://a.example.com"])
        #expect(extracted?.writeRelays == ["wss://b.example.com"])
    }

    @Test("relayListMetadata returns nil for non-10002 event")
    func relayListNilForOtherKind() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = try signer.signTextNote(content: "Hello")
        #expect(textNote.relayListMetadata == nil)
        #expect(textNote.isRelayListMetadata == false)
    }

    @Test("isRelayListMetadata property")
    func isRelayListMetadataProperty() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let relayListEvent = try signer.signRelayListMetadata(
            RelayListMetadata(entries: [RelayListEntry(url: "wss://a.example.com")])
        )
        let textNote = try signer.signTextNote(content: "Hello")

        #expect(relayListEvent.isRelayListMetadata == true)
        #expect(textNote.isRelayListMetadata == false)
    }
}

@Suite("Relay List Metadata Filter Tests (NIP-65)")
struct RelayListMetadataFilterTests {

    @Test("Relay list filter for single pubkey")
    func filterSinglePubkey() {
        let filter = Filter.relayListMetadata(pubkey: "abc123")
        #expect(filter.authors == ["abc123"])
        #expect(filter.kinds == [10002])
        #expect(filter.limit == 1)
    }

    @Test("Relay list filter for multiple pubkeys")
    func filterMultiplePubkeys() {
        let filter = Filter.relayListMetadata(pubkeys: ["abc123", "def456"])
        #expect(filter.authors == ["abc123", "def456"])
        #expect(filter.kinds == [10002])
        #expect(filter.limit == nil)
    }
}
