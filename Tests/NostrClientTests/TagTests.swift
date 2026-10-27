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
        #expect(tag.rawArray == raw)
        #expect(tag == Event.Tag(name: .event, values: ["abc", "", "reply"]))
        #expect(Event.Tag(rawArray: ["t", "nostr"]) == .hashtag("nostr"))
    }

    /// NIP-01 does not forbid an empty tag array, and dropping one would change the event id, so
    /// it is kept as is rather than folded into the name-only tag `[""]`.
    @Test("an empty raw array is kept distinct from an empty name")
    func emptyRawArrayIsKept() {
        let empty = Event.Tag(rawArray: [])
        #expect(empty.rawArray == [])
        #expect(empty.name == "")
        #expect(empty.values.isEmpty)
        #expect(empty.primaryValue == nil)
        #expect(empty != Event.Tag(name: ""))
        #expect(Event.Tag(name: "").rawArray == [""])
    }

    // MARK: - Tag Name

    @Test(
        "name constants carry their wire strings",
        arguments: [
            (Event.Tag.Name.event, "e"), (.quote, "q"), (.publicKey, "p"), (.hashtag, "t"),
            (.identifier, "d"), (.subject, "subject"), (.relay, "relay"), (.challenge, "challenge"),
            (.url, "u"), (.method, "method"), (.payload, "payload"), (.expiration, "expiration"),
            (.kind, "k"), (.nonce, "nonce"), (.word, "word"), (.address, "a"), (.reference, "r"),
            (.group, "h"), (.previous, "previous"), (.inviteCode, "code"), (.role, "role"),
            (.simpleGroup, "group"),
        ]
    )
    func nameConstantsCarryWireStrings(name: Event.Tag.Name, rawValue: String) {
        #expect(name.rawValue == rawValue)
        #expect(name.description == rawValue)
    }

    @Test("names from literals and raw values compare equal")
    func nameLiteralAndRawValueEquality() {
        let literal: Event.Tag.Name = "t"
        #expect(literal == .hashtag)
        #expect(Event.Tag.Name(rawValue: "t") == .hashtag)
        #expect(Event.Tag.Name(rawValue: "T") != .hashtag)
    }

    @Test("names encode as bare JSON strings")
    func nameEncodesAsBareString() throws {
        let data = try JSONEncoder().encode(Event.Tag.Name.inviteCode)
        #expect(String(data: data, encoding: .utf8) == #""code""#)
        #expect(try JSONDecoder().decode(Event.Tag.Name.self, from: data) == .inviteCode)
    }

    @Test("an unknown tag name round-trips through Codable")
    func unknownNameRoundTrips() throws {
        let json = #"["x-custom","value"]"#
        let tag = try JSONDecoder().decode(Event.Tag.self, from: Data(json.utf8))
        #expect(tag.name == Event.Tag.Name(rawValue: "x-custom"))
        #expect(tag.values == ["value"])
        #expect(String(data: try JSONEncoder().encode(tag), encoding: .utf8) == json)
    }

    @Test("typed constructors use the name constants")
    func typedConstructorsUseNameConstants() {
        let pairs: [(Event.Tag, Event.Tag.Name)] = [
            (.event(id1), .event),
            (.quote(id1), .quote),
            (.publicKey(pk1), .publicKey),
            (.publicKey(pk1, roles: ["admin"]), .publicKey),
            (.hashtag("nostr"), .hashtag),
            (.identifier("x"), .identifier),
            (.subject("hello"), .subject),
            (.relay(relay), .relay),
            (.challenge("c"), .challenge),
            (.url("https://example.com"), .url),
            (.method("GET"), .method),
            (.payload(sha256: "00"), .payload),
            (.expiration(Timestamp(rawValue: 1)), .expiration),
            (.kind(.textNote), .kind),
            (.nonce("1", target: 8), .nonce),
            (.word("spam"), .word),
            (.address(EventCoordinate(kind: .longFormContent, publicKey: pk1, identifier: "post")), .address),
            (.reference("https://example.com"), .reference),
            (.group("g"), .group),
            (.previous(["abcd1234"]), .previous),
            (.inviteCode("invite"), .inviteCode),
            (.role("admin"), .role),
            (.simpleGroup(id: "g", relayURL: relay), .simpleGroup),
        ]
        for (tag, name) in pairs {
            #expect(tag.name == name)
        }
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
        #expect(Event.Tag.event(id1, publicKey: pk1).rawArray == ["e", id1.hex, "", "", pk1.hex])
        #expect(
            Event.Tag.event(id1, marker: .mention, publicKey: pk1).rawArray == [
                "e", id1.hex, "", "mention", pk1.hex,
            ])
    }

    @Test("public key tag pads skipped relay before petname")
    func publicKeyTagPadsRelay() {
        #expect(Event.Tag.publicKey(pk1).rawArray == ["p", pk1.hex])
        #expect(Event.Tag.publicKey(pk1, relayURL: relay).rawArray == ["p", pk1.hex, "wss://r.example"])
        #expect(Event.Tag.publicKey(pk1, petname: "alice").rawArray == ["p", pk1.hex, "", "alice"])
        #expect(
            Event.Tag.publicKey(pk1, relayURL: relay, petname: "alice").rawArray == [
                "p", pk1.hex, "wss://r.example", "alice",
            ])
    }

    @Test("relay hints are written in canonical form")
    func relayHintsAreCanonical() throws {
        let spelled = try RelayURL(string: "WSS://R.Example:443/")
        #expect(Event.Tag.event(id1, relayURL: spelled).rawArray == ["e", id1.hex, "wss://r.example"])
        #expect(Event.Tag.quote(id1, relayURL: spelled).rawArray == ["q", id1.hex, "wss://r.example"])
        #expect(Event.Tag.publicKey(pk1, relayURL: spelled).rawArray == ["p", pk1.hex, "wss://r.example"])
        #expect(
            Event.Tag.address(
                EventCoordinate(kind: .longFormContent, publicKey: pk1, identifier: "a"), relayURL: spelled
            ).rawArray == ["a", "30023:\(pk1.hex):a", "wss://r.example"])
        #expect(Event.Tag.relay(spelled).rawArray == ["relay", "wss://r.example"])
    }

    @Test("public key tag matches Contact.tag")
    func publicKeyTagMatchesContactTag() throws {
        let contacts = [
            Contact(publicKey: pk1),
            Contact(publicKey: pk1, relayURL: relay),
            Contact(publicKey: pk1, petname: "alice"),
            Contact(publicKey: pk1, relayURL: relay, petname: "alice"),
        ]
        for contact in contacts {
            let tag = Event.Tag.publicKey(contact.publicKey, relayURL: contact.relayURL, petname: contact.petname)
            #expect(tag == contact.tag)
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

    @Test("decodes from a bare JSON array, including an empty one")
    func decodesFromBareArray() throws {
        let tag = try JSONDecoder().decode(Event.Tag.self, from: Data(#"["t","nostr"]"#.utf8))
        #expect(tag == .hashtag("nostr"))

        let empty = try JSONDecoder().decode(Event.Tag.self, from: Data("[]".utf8))
        #expect(empty.rawArray == [])
    }

    // MARK: - UnsignedEvent Integration

    @Test("UnsignedEvent stores tags in raw wire form")
    func unsignedEventStoresRawWireForm() {
        let unsigned = UnsignedEvent(
            publicKey: PublicKey.fixture("pk"),
            kind: .textNote,
            tags: [.hashtag("nostr"), .event(id1, marker: .reply)],
            content: "hi"
        )
        #expect(unsigned.tags.map(\.rawArray) == [["t", "nostr"], ["e", id1.hex, "", "reply"]])
    }

    @Test("Tag-built and raw-built events hash identically")
    func tagAndRawBuiltEventsHashIdentically() throws {
        let viaTags = UnsignedEvent(
            publicKey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .textNote,
            tags: [.event(id1, marker: .reply), .publicKey(pk2)],
            content: "hi"
        )
        let viaRaw = UnsignedEvent(
            publicKey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            tags: [Event.Tag(name: .event, values: [id1.hex, "", "reply"]), .publicKey(pk2)],
            content: "hi"
        )
        #expect(viaTags.serializedForHashing() == viaRaw.serializedForHashing())
    }

    @Test("signed events carry typed tags and verify")
    func signedEventsCarryTypedTags() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.textNote("hi", tags: [.hashtag("nostr")]))
        #expect(event.tags.map(\.rawArray) == [["t", "nostr"]])
        try event.verify()
    }

    // MARK: - Event Accessors

    private func makeEvent(tags: [Event.Tag]) -> Event {
        Event(
            id: EventID.fixture("id"),
            publicKey: PublicKey.fixture("pk"),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            tags: tags,
            content: "",
            signature: nil
        )
    }

    @Test("tags(named:) filters by name")
    func tagsNamedFilters() {
        let event = makeEvent(tags: [
            .event(id1), .publicKey(pk1), Event.Tag(name: .event, values: [id2.hex, "", "reply"]),
        ])
        #expect(event.tags(named: "e") == [.event(id1), .event(id2, marker: .reply)])
        #expect(event.tags(named: "x").isEmpty)
        #expect(event.tags(named: .publicKey) == [.publicKey(pk1)])
    }

    @Test("firstTagValue returns the first value of the first match")
    func firstTagValueReturnsFirstMatch() {
        let event = makeEvent(tags: [.subject("greetings"), .subject("second"), Event.Tag(name: .event)])
        #expect(event.firstTagValue(named: "subject") == "greetings")
        #expect(event.firstTagValue(named: "e") == nil)
        #expect(event.firstTagValue(named: "missing") == nil)
        #expect(event.firstTagValue(named: .subject) == "greetings")
    }

    @Test("referenced ids and public keys")
    func referencedIDsAndPublicKeys() {
        let event = makeEvent(tags: [
            .event(id1), Event.Tag(name: .event, values: [id2.hex, "wss://r.example"]), .publicKey(pk1),
            Event.Tag(name: .event), Event.Tag(rawArray: []), .publicKey(pk2),
        ])
        #expect(event.referencedEventIDs == [id1, id2])
        #expect(event.referencedPublicKeys == [pk1, pk2])
    }

    /// Tags are written by whoever authored the event, so a value that is not a canonical id or
    /// key is not something to hand back typed — it is skipped, keeping the well-formed ones.
    @Test("referenced ids and public keys skip malformed values")
    func referencedValuesSkipMalformed() {
        let event = makeEvent(
            tags: [
                ["e", "id1"], ["e", id1.hex.uppercased()], ["e", id2.hex],
                ["p", "pk1"], ["p", String(pk1.hex.dropLast())], ["p", pk2.hex],
            ].map(Event.Tag.init(rawArray:)))
        #expect(event.referencedEventIDs == [id2])
        #expect(event.referencedPublicKeys == [pk2])
    }

    @Test("quote and address tags write ids and keys as hex")
    func quoteAndAddressTags() {
        #expect(Event.Tag.quote(id1).rawArray == ["q", id1.hex])
        #expect(Event.Tag.quote(id1, publicKey: pk1).rawArray == ["q", id1.hex, "", pk1.hex])
        #expect(
            Event.Tag.address(EventCoordinate(kind: .longFormContent, publicKey: pk1, identifier: "post")).rawArray
                == ["a", "30023:\(pk1.hex):post"])
    }
}
