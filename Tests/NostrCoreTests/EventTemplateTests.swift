import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("EventTemplate Tests")
struct EventTemplateTests {
    private let relayURL = RelayURL("wss://relay.example.com")!

    private func note(_ content: String = "gm") throws -> Event {
        try EventSigner(keyPair: try KeyPair()).sign(.textNote(content))
    }

    // MARK: - Template and UnsignedEvent

    @Test("init defaults to no tags, empty content, and the current time")
    func initDefaults() {
        let before = Timestamp.now
        let template = EventTemplate(kind: .textNote)

        #expect(template.kind == .textNote)
        #expect(template.tags.isEmpty)
        #expect(template.content.isEmpty)
        #expect(template.createdAt >= before && template.createdAt <= .now)
    }

    @Test("UnsignedEvent(_:publicKey:) carries every template field under the given key")
    func unsignedEventFromTemplate() {
        let template = EventTemplate(
            kind: .reaction,
            tags: [.event(.fixture("note")), .hashtag("nostr")],
            content: "+",
            createdAt: Timestamp(rawValue: 1_700_000_000)
        )

        let unsigned = UnsignedEvent(template, publicKey: .fixture("author"))

        #expect(unsigned.publicKey == .fixture("author"))
        #expect(unsigned.kind == .reaction)
        #expect(unsigned.tags == [["e", EventID.fixture("note").hex], ["t", "nostr"]])
        #expect(unsigned.content == "+")
        #expect(unsigned.createdAt == Timestamp(rawValue: 1_700_000_000))
    }

    @Test("a template's fields can be edited before it is signed")
    func editBeforeSigning() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let expiry = Timestamp(rawValue: 1_700_003_600)

        var template = EventTemplate.textNote("draft")
        template.content = "final"
        template.tags.append(.expiration(expiry))
        template.createdAt = Timestamp(rawValue: 1_700_000_000)
        let event = try signer.sign(template)

        #expect(event.content == "final")
        #expect(event.tags == [["expiration", "1700003600"]])
        #expect(event.createdAt == Timestamp(rawValue: 1_700_000_000))
        #expect(try event.verify())
    }

    // MARK: - Factories

    @Test("textNote is kind 1 with the given content and tags")
    func textNote() {
        let template = EventTemplate.textNote("gm", tags: [.hashtag("nostr")])

        #expect(template.kind == .textNote)
        #expect(template.content == "gm")
        #expect(template.tags == [.hashtag("nostr")])
        #expect(EventTemplate.textNote("gm").tags.isEmpty)
    }

    @Test("reaction references the event and its author, liking by default")
    func reaction() throws {
        let note = try note()

        let like = EventTemplate.reaction(to: note)
        let custom = EventTemplate.reaction(to: note, content: "🤙")

        #expect(like.kind == .reaction)
        #expect(like.content == "+")
        #expect(like.tags.map(\.rawArray) == [["e", note.id.hex], ["p", note.publicKey.hex]])
        #expect(custom.content == "🤙")
    }

    @Test("repost embeds the event and records it, its author, and the relay")
    func repost() throws {
        let note = try note()

        let template = try EventTemplate.repost(of: note, relayURL: relayURL)

        #expect(template.kind == .repost)
        #expect(
            template.tags.map(\.rawArray) == [
                ["e", note.id.hex, "wss://relay.example.com"], ["p", note.publicKey.hex],
            ])
        #expect(try JSONDecoder().decode(Event.self, from: Data(template.content.utf8)) == note)
    }

    @Test("repost omits the relay when none is given")
    func repostWithoutRelayURL() throws {
        let note = try note()

        let template = try EventTemplate.repost(of: note)

        #expect(template.tags.map(\.rawArray) == [["e", note.id.hex], ["p", note.publicKey.hex]])
    }

    @Test("deletion writes one e tag per event id, in order, with the reason as content")
    func deletion() {
        let template = EventTemplate.deletion(of: [.fixture("first"), .fixture("second")], reason: "oops")

        #expect(template.kind == .eventDeletion)
        #expect(
            template.tags.map(\.rawArray) == [
                ["e", EventID.fixture("first").hex], ["e", EventID.fixture("second").hex],
            ])
        #expect(template.content == "oops")
        #expect(EventTemplate.deletion(of: [.fixture("first")]).content.isEmpty)
    }

    @Test("clientAuthentication carries the canonical relay URL and the challenge (NIP-42)")
    func clientAuthentication() throws {
        let relay = try RelayURL(string: "wss://Relay.Example.com/")

        let template = EventTemplate.clientAuthentication(relayURL: relay, challenge: "abc123")

        #expect(template.kind == .clientAuthentication)
        #expect(template.tags.map(\.rawArray) == [["relay", "wss://relay.example.com"], ["challenge", "abc123"]])
        #expect(template.content.isEmpty)
    }

    @Test("zapRequest writes every tag in order, with the comment as content (NIP-57)")
    func zapRequest() throws {
        let template = try EventTemplate.zapRequest(
            to: .fixture("recipient"),
            relays: [relayURL, RelayURL("wss://relay2.example.com")!],
            amountMillisats: 21000,
            lnurl: "lnurl1example",
            eventID: .fixture("note"),
            eventCoordinate: "30023:author:identifier",
            comment: "great post"
        )

        #expect(template.kind == .zapRequest)
        #expect(template.content == "great post")
        #expect(
            template.tags.map(\.rawArray) == [
                ["relays", "wss://relay.example.com", "wss://relay2.example.com"],
                ["p", PublicKey.fixture("recipient").hex],
                ["amount", "21000"],
                ["lnurl", "lnurl1example"],
                ["e", EventID.fixture("note").hex],
                ["a", "30023:author:identifier"],
            ])
    }

    @Test("zapRequest omits the optional tags when they are not given")
    func zapRequestMinimal() throws {
        let template = try EventTemplate.zapRequest(to: .fixture("recipient"), relays: [relayURL])

        #expect(
            template.tags.map(\.rawArray) == [
                ["relays", "wss://relay.example.com"], ["p", PublicKey.fixture("recipient").hex],
            ])
        #expect(template.content.isEmpty)
    }

    @Test("zapRequest requires at least one relay")
    func zapRequestRequiresRelay() {
        #expect(throws: NostrError.invalidData) {
            _ = try EventTemplate.zapRequest(to: .fixture("recipient"), relays: [])
        }
    }
}
