import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Tag Tests")
struct TagTests {
    private let id1 = EventID.fixture("id1")
    private let id2 = EventID.fixture("id2")
    private let pk1 = PublicKey.fixture("pk1")
    private let pk2 = PublicKey.fixture("pk2")
    private let relay = RelayURL("wss://r.example")!

    // MARK: - Construction

    @Test("init splits name and values")
    func initSplitsNameAndValues() {
        let tag = Event.Tag(name: "e", values: ["abc", "wss://relay.example.com"])
        #expect(tag.name == "e")
        #expect(tag.values == ["abc", "wss://relay.example.com"])
        #expect(tag.rawArray == ["e", "abc", "wss://relay.example.com"])
        #expect(tag.primaryValue == "abc")
    }

    @Test("rawArray round-trips")
    func rawArrayRoundTrips() {
        let raw = ["e", "abc", "", "reply"]
        let tag = Event.Tag(rawArray: raw)
        #expect(tag?.rawArray == raw)
    }

    @Test("init(rawArray:) returns nil for an empty array")
    func initRawArrayNilForEmpty() {
        #expect(Event.Tag(rawArray: []) == nil)
        #expect(Event.Tag.raw([]) == nil)
        #expect(Event.Tag.raw(["x"]) == Event.Tag(name: "x"))
    }

    @Test("array literal builds a tag")
    func arrayLiteralBuildsTag() {
        let tag: Event.Tag = ["t", "nostr"]
        #expect(tag.name == "t")
        #expect(tag.values == ["nostr"])
        #expect(tag == Event.Tag.hashtag("nostr"))
    }

    // MARK: - Typed Constructors

    @Test("event tag pads skipped middle elements")
    func eventTagPadsSkippedElements() {
        #expect(Event.Tag.event(id1).rawArray == ["e", id1.hex])
        #expect(Event.Tag.event(id1, relayURL: relay).rawArray == ["e", id1.hex, "wss://r.example"])
        #expect(Event.Tag.event(id1, marker: .reply).rawArray == ["e", id1.hex, "", "reply"])
        #expect(
            Event.Tag.event(id1, relayURL: relay, marker: .root).rawArray == [
                "e", id1.hex, "wss://r.example", "root",
            ])
        #expect(Event.Tag.event(id1, pubkey: pk1).rawArray == ["e", id1.hex, "", "", pk1.hex])
        #expect(
            Event.Tag.event(id1, marker: .mention, pubkey: pk1).rawArray == [
                "e", id1.hex, "", "mention", pk1.hex,
            ])
    }

    @Test("pubkey tag pads skipped relay before petname")
    func pubkeyTagPadsRelay() {
        #expect(Event.Tag.pubkey(pk1).rawArray == ["p", pk1.hex])
        #expect(Event.Tag.pubkey(pk1, relayURL: relay).rawArray == ["p", pk1.hex, "wss://r.example"])
        #expect(Event.Tag.pubkey(pk1, petname: "alice").rawArray == ["p", pk1.hex, "", "alice"])
        #expect(
            Event.Tag.pubkey(pk1, relayURL: relay, petname: "alice").rawArray == [
                "p", pk1.hex, "wss://r.example", "alice",
            ])
    }

    @Test("relay hints are written in canonical form")
    func relayHintsAreCanonical() throws {
        let spelled = try RelayURL(string: "WSS://R.Example:443/")
        #expect(Event.Tag.event(id1, relayURL: spelled).rawArray == ["e", id1.hex, "wss://r.example"])
        #expect(Event.Tag.quote(id1, relayURL: spelled).rawArray == ["q", id1.hex, "wss://r.example"])
        #expect(Event.Tag.pubkey(pk1, relayURL: spelled).rawArray == ["p", pk1.hex, "wss://r.example"])
        #expect(
            Event.Tag.address(kind: .longFormContent, pubkey: pk1, identifier: "a", relayURL: spelled).rawArray == [
                "a", "30023:\(pk1.hex):a", "wss://r.example",
            ])
        #expect(Event.Tag.relay(spelled).rawArray == ["relay", "wss://r.example"])
    }

    @Test("pubkey tag matches Contact.toTag output")
    func pubkeyTagMatchesContactToTag() throws {
        let contacts = [
            Contact(pubkey: pk1),
            Contact(pubkey: pk1, relayURL: relay),
            Contact(pubkey: pk1, petname: "alice"),
            Contact(pubkey: pk1, relayURL: relay, petname: "alice"),
        ]
        for contact in contacts {
            let tag = Event.Tag.pubkey(contact.pubkey, relayURL: contact.relayURL, petname: contact.petname)
            #expect(tag.rawArray == contact.toTag())
        }
    }

    @Test("simple constructors")
    func simpleConstructors() {
        #expect(Event.Tag.hashtag("nostr").rawArray == ["t", "nostr"])
        #expect(Event.Tag.identifier("my-article").rawArray == ["d", "my-article"])
        #expect(Event.Tag.subject("hello").rawArray == ["subject", "hello"])
    }

    // MARK: - Codable

    @Test("encodes as a bare JSON array")
    func encodesAsBareArray() throws {
        let tag = Event.Tag.event(id1, marker: .reply)
        let data = try JSONEncoder().encode(tag)
        #expect(String(data: data, encoding: .utf8) == #"["e","\#(id1.hex)","","reply"]"#)
    }

    @Test("decodes from a bare JSON array and rejects empty arrays")
    func decodesFromBareArray() throws {
        let tag = try JSONDecoder().decode(Event.Tag.self, from: Data(#"["t","nostr"]"#.utf8))
        #expect(tag == .hashtag("nostr"))

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Event.Tag.self, from: Data("[]".utf8))
        }
    }

    // MARK: - UnsignedEvent Integration

    @Test("UnsignedEvent stores tags in raw wire form")
    func unsignedEventStoresRawWireForm() {
        let unsigned = UnsignedEvent(
            pubkey: PublicKey.fixture("pk"),
            kind: .textNote,
            tags: [.hashtag("nostr"), .event(id1, marker: .reply)],
            content: "hi"
        )
        #expect(unsigned.tags == [["t", "nostr"], ["e", id1.hex, "", "reply"]])
    }

    @Test("UnsignedEvent rawTags initializer keeps arrays untouched")
    func unsignedEventRawTagsUntouched() {
        let raw = [["e", id1.hex, "wss://r.example", "root"], ["custom", "x", "y"]]
        let unsigned = UnsignedEvent(pubkey: PublicKey.fixture("pk"), kind: 1, rawTags: raw, content: "hi")
        #expect(unsigned.tags == raw)
    }

    @Test("Tag-built and raw-built events hash identically")
    func tagAndRawBuiltEventsHashIdentically() throws {
        let viaTags = UnsignedEvent(
            pubkey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .textNote,
            tags: [.event(id1, marker: .reply), .pubkey(pk2)],
            content: "hi"
        )
        let viaRaw = UnsignedEvent(
            pubkey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            rawTags: [["e", id1.hex, "", "reply"], ["p", pk2.hex]],
            content: "hi"
        )
        #expect(try viaTags.serializedForHashing() == viaRaw.serializedForHashing())
    }

    @Test("signed events carry typed tags and verify")
    func signedEventsCarryTypedTags() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signTextNote(content: "hi", tags: [.hashtag("nostr")])
        #expect(event.tags == [["t", "nostr"]])
        #expect(try event.verify())
    }

    // MARK: - Event Accessors

    private func makeEvent(tags: [[String]]) -> Event {
        Event(
            id: EventID.fixture("id"),
            pubkey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            tags: tags,
            content: "",
            signature: nil
        )
    }

    @Test("structuredTags skips malformed empty arrays")
    func structuredTagsSkipsEmptyArrays() {
        let event = makeEvent(tags: [["e", id1.hex], [], ["t", "nostr"]])
        #expect(event.structuredTags == [.event(id1), .hashtag("nostr")])
    }

    @Test("tags(named:) filters by name")
    func tagsNamedFilters() {
        let event = makeEvent(tags: [["e", id1.hex], ["p", pk1.hex], ["e", id2.hex, "", "reply"]])
        #expect(event.tags(named: "e") == [.event(id1), .event(id2, marker: .reply)])
        #expect(event.tags(named: "x").isEmpty)
    }

    @Test("firstTagValue returns the first value of the first match")
    func firstTagValueReturnsFirstMatch() {
        let event = makeEvent(tags: [["subject", "greetings"], ["subject", "second"], ["e"]])
        #expect(event.firstTagValue(named: "subject") == "greetings")
        #expect(event.firstTagValue(named: "e") == nil)
        #expect(event.firstTagValue(named: "missing") == nil)
    }

    @Test("referenced ids and pubkeys")
    func referencedIDsAndPubkeys() {
        let event = makeEvent(tags: [
            ["e", id1.hex], ["e", id2.hex, "wss://r.example"], ["p", pk1.hex], ["e"], ["p", pk2.hex],
        ])
        #expect(event.referencedEventIDs == [id1, id2])
        #expect(event.referencedPubkeys == [pk1, pk2])
    }

    /// Tags are written by whoever authored the event, so a value that is not a canonical id or
    /// key is not something to hand back typed — it is skipped, keeping the well-formed ones.
    @Test("referenced ids and pubkeys skip malformed values")
    func referencedValuesSkipMalformed() {
        let event = makeEvent(tags: [
            ["e", "id1"], ["e", id1.hex.uppercased()], ["e", id2.hex],
            ["p", "pk1"], ["p", String(pk1.hex.dropLast())], ["p", pk2.hex],
        ])
        #expect(event.referencedEventIDs == [id2])
        #expect(event.referencedPubkeys == [pk2])
    }

    @Test("quote and address tags write ids and keys as hex")
    func quoteAndAddressTags() {
        #expect(Event.Tag.quote(id1).rawArray == ["q", id1.hex])
        #expect(Event.Tag.quote(id1, pubkey: pk1).rawArray == ["q", id1.hex, "", pk1.hex])
        #expect(
            Event.Tag.address(kind: .longFormContent, pubkey: pk1, identifier: "post").rawArray
                == ["a", "30023:\(pk1.hex):post"])
    }
}
