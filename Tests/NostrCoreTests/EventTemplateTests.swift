import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("EventTemplate Tests")
struct EventTemplateTests {
    private let relayURL = RelayURL("wss://relay.example.com")!

    private func note(_ content: String = "gm") throws -> Event {
        EventSigner(keyPair: KeyPair()).sign(.textNote(content))
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
        #expect(unsigned.tags.map(\.rawArray) == [["e", EventID.fixture("note").hex], ["t", "nostr"]])
        #expect(unsigned.content == "+")
        #expect(unsigned.createdAt == Timestamp(rawValue: 1_700_000_000))
    }

    @Test("a template's fields can be edited before it is signed")
    func editBeforeSigning() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let expiry = Timestamp(rawValue: 1_700_003_600)

        var template = EventTemplate.textNote("draft")
        template.content = "final"
        template.tags.append(.expiration(expiry))
        template.createdAt = Timestamp(rawValue: 1_700_000_000)
        let event = signer.sign(template)

        #expect(event.content == "final")
        #expect(event.tags.map(\.rawArray) == [["expiration", "1700003600"]])
        #expect(event.createdAt == Timestamp(rawValue: 1_700_000_000))
        try event.verify()
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

    // MARK: - Replies (NIP-10)

    private let rootID = EventID.fixture("root")
    private let siblingID = EventID.fixture("sibling")

    /// A note carrying `tags`, to be replied to.
    private func parent(tags: [Event.Tag]) throws -> Event {
        let signer = EventSigner(keyPair: KeyPair())
        return try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1_700_000_000), kind: .textNote,
                tags: tags, content: "parent"))
    }

    @Test("a reply to an event with no e tags names it as the root and mentions its author")
    func replyToRootEvent() throws {
        let parent = try parent(tags: [.publicKey(.fixture("someone"))])

        let reply = EventTemplate.reply(to: parent, content: "a reply")
        let hinted = EventTemplate.reply(to: parent, content: "a reply", relayURL: relayURL)

        #expect(reply.kind == .textNote)
        #expect(reply.content == "a reply")
        #expect(reply.tags.map(\.rawArray) == [["e", parent.id.hex, "", "root"], ["p", parent.publicKey.hex]])
        #expect(hinted.tags.first?.rawArray == ["e", parent.id.hex, "wss://relay.example.com", "root"])
    }

    @Test("a reply carries the parent's marked root over verbatim and marks the parent as replied to")
    func replyCarriesMarkedRoot() throws {
        let parent = try parent(tags: [
            Event.Tag(
                name: .event, values: [rootID.hex, "wss://root.example.com", "root", PublicKey.fixture("op").hex]),
            Event.Tag(name: .event, values: [siblingID.hex, "wss://root.example.com", "reply"]),
        ])

        let reply = EventTemplate.reply(to: parent, content: "a reply", relayURL: relayURL)

        #expect(
            reply.tags.map(\.rawArray) == [
                ["e", rootID.hex, "wss://root.example.com", "root", PublicKey.fixture("op").hex],
                ["e", parent.id.hex, "wss://relay.example.com", "reply"],
                ["p", parent.publicKey.hex],
            ])
    }

    /// The marker is read at its fixed position: "root" in the relay-hint slot of a tag marked
    /// "reply" is not a marker, so the parent has no root and is itself the root.
    @Test("a value of root outside the marker position is not a marker")
    func replyIgnoresRootOutsideMarkerPosition() throws {
        let parent = try parent(tags: [Event.Tag(name: .event, values: [siblingID.hex, "root", "reply"])])

        let reply = EventTemplate.reply(to: parent, content: "a reply")

        #expect(reply.tags.map(\.rawArray) == [["e", parent.id.hex, "", "root"], ["p", parent.publicKey.hex]])
    }

    @Test("a marked thread with no root marker is treated as rootless")
    func replyToMarkedButRootlessThread() throws {
        let parent = try parent(tags: [
            Event.Tag(name: .event, values: [siblingID.hex, "wss://root.example.com", "mention"])
        ])

        let reply = EventTemplate.reply(to: parent, content: "a reply")

        #expect(reply.tags.map(\.rawArray) == [["e", parent.id.hex, "", "root"], ["p", parent.publicKey.hex]])
    }

    /// In NIP-10's deprecated positional form the first `e` tag is the root. It is re-emitted with an
    /// explicit marker, keeping a relay hint that is a valid relay URL in canonical form.
    @Test("a positional root is re-emitted marked, with a valid relay hint canonicalized")
    func replyRecoversPositionalRootWithValidHint() throws {
        let parent = try parent(tags: [
            Event.Tag(name: .event, values: [rootID.hex, "WSS://Hint.Example.com/"]), .event(siblingID),
        ])

        let reply = EventTemplate.reply(to: parent, content: "a reply")

        #expect(
            reply.tags.map(\.rawArray) == [
                ["e", rootID.hex, "wss://hint.example.com", "root"],
                ["e", parent.id.hex, "", "reply"],
                ["p", parent.publicKey.hex],
            ])
    }

    @Test("a positional root drops a relay hint that is not a relay URL")
    func replyRecoversPositionalRootWithInvalidHint() throws {
        let parent = try parent(tags: [
            Event.Tag(name: .event, values: [rootID.hex, "https://not-a-relay.example.com"]), .event(siblingID),
        ])

        let reply = EventTemplate.reply(to: parent, content: "a reply")

        #expect(
            reply.tags.map(\.rawArray) == [
                ["e", rootID.hex, "", "root"], ["e", parent.id.hex, "", "reply"], ["p", parent.publicKey.hex],
            ])
    }

    @Test("a positional root whose id is not an event id leaves the parent as the root")
    func replyIgnoresMalformedPositionalRoot() throws {
        let parent = try parent(tags: [Event.Tag(name: .event, values: ["not-an-event-id"])])

        let reply = EventTemplate.reply(to: parent, content: "a reply")

        #expect(reply.tags.map(\.rawArray) == [["e", parent.id.hex, "", "root"], ["p", parent.publicKey.hex]])
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

        let template = EventTemplate.repost(of: note, relayURL: relayURL)

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

        let template = EventTemplate.repost(of: note)

        #expect(template.tags.map(\.rawArray) == [["e", note.id.hex], ["p", note.publicKey.hex]])
    }

    @Test("deletion writes one e tag per event id, in order, with the reason as content")
    func deletion() {
        let template = EventTemplate.deletion(of: [.fixture("first"), .fixture("second")], reason: "oops")

        #expect(template.kind == .deletionRequest)
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
            eventCoordinate: EventCoordinate(
                kind: .longFormContent, publicKey: .fixture("author"), identifier: "identifier"),
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
                ["a", "30023:\(PublicKey.fixture("author").hex):identifier"],
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
        #expect(throws: EventTemplate.ZapRequestError.missingRelays) {
            _ = try EventTemplate.zapRequest(to: .fixture("recipient"), relays: [])
        }
    }
}
