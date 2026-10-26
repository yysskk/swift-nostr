import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("EventTemplate NostrClient Factory Tests")
struct EventTemplateClientTests {
    private func note() throws -> Event {
        try EventSigner(keyPair: try KeyPair()).sign(.textNote("reported"))
    }

    // MARK: - Profiles and contacts

    @Test("metadata is kind 0 with the profile encoded as JSON and no tags")
    func metadata() throws {
        let template = try EventTemplate.metadata(UserMetadata(name: "alice", displayName: "Alice"))

        #expect(template.kind == .setMetadata)
        #expect(template.tags.isEmpty)
        let decoded = try JSONSerialization.jsonObject(with: Data(template.content.utf8)) as? [String: String]
        #expect(decoded == ["name": "alice", "display_name": "Alice"])
    }

    @Test("contactList is kind 3 with one p tag per contact, in order, and empty content")
    func contactList() {
        let template = EventTemplate.contactList([
            Contact(publicKey: .fixture("alice"), relayURL: RelayURL("wss://relay.example.com")!, petname: "alice"),
            Contact(publicKey: .fixture("bob")),
        ])

        #expect(template.kind == .contacts)
        #expect(
            template.tags.map(\.rawArray) == [
                ["p", PublicKey.fixture("alice").hex, "wss://relay.example.com", "alice"],
                ["p", PublicKey.fixture("bob").hex],
            ])
        #expect(template.content.isEmpty)
        #expect(EventTemplate.contactList([]).tags.isEmpty)
    }

    // MARK: - Relay lists

    @Test("relayListMetadata is kind 10002 with the list's r tags and empty content")
    func relayListMetadata() {
        let relayList = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://both.example.com")!),
            RelayListEntry(url: RelayURL("wss://read.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://write.example.com")!, usage: .write),
        ])

        let template = EventTemplate.relayListMetadata(relayList)

        #expect(template.kind == .relayListMetadata)
        #expect(
            template.tags.map(\.rawArray) == [
                ["r", "wss://both.example.com"],
                ["r", "wss://read.example.com", "read"],
                ["r", "wss://write.example.com", "write"],
            ])
        #expect(template.content.isEmpty)
    }

    @Test("directMessageRelayList is kind 10050 with one relay tag per relay and empty content")
    func directMessageRelayList() {
        let relayList = DirectMessageRelayList(relays: [
            RelayURL("wss://inbox.example.com")!, RelayURL("wss://dm.example.com")!,
        ])

        let template = EventTemplate.directMessageRelayList(relayList)

        #expect(template.kind == .directMessageRelayList)
        #expect(
            template.tags.map(\.rawArray) == [
                ["relay", "wss://inbox.example.com"],
                ["relay", "wss://dm.example.com"],
            ])
        #expect(template.content.isEmpty)
    }

    // MARK: - Reports

    @Test("report of a public key is kind 1984 with the type on the p tag and the reason as content")
    func reportPublicKey() {
        let template = EventTemplate.report(.fixture("spammer"), type: .spam, reason: "unsolicited")

        #expect(template.kind == .report)
        #expect(template.tags.map(\.rawArray) == [["p", PublicKey.fixture("spammer").hex, "spam"]])
        #expect(template.content == "unsolicited")
        #expect(EventTemplate.report(.fixture("spammer"), type: .spam).content.isEmpty)
    }

    @Test("report of an event carries the type on the e tag and a bare p tag for the author")
    func reportEvent() throws {
        let note = try note()

        let template = EventTemplate.report(note, type: .illegal, reason: "against the law")

        #expect(template.kind == .report)
        #expect(
            template.tags.map(\.rawArray) == [
                ["e", note.id.hex, "illegal"],
                ["p", note.publicKey.hex],
            ])
        #expect(template.content == "against the law")
    }

    // MARK: - Long-form content

    @Test("longFormContent is kind 30023 with the article's tags and Markdown body")
    func longFormContent() {
        let article = LongFormContent(
            identifier: "intro",
            title: "Intro",
            summary: "A summary",
            imageURL: "https://example.com/cover.png",
            publishedAt: Timestamp(rawValue: 1_700_000_000),
            hashtags: ["nostr"],
            content: "# Hello"
        )

        let template = EventTemplate.longFormContent(article)

        #expect(template.kind == .longFormContent)
        #expect(
            template.tags.map(\.rawArray) == [
                ["d", "intro"],
                ["title", "Intro"],
                ["summary", "A summary"],
                ["image", "https://example.com/cover.png"],
                ["published_at", "1700000000"],
                ["t", "nostr"],
            ])
        #expect(template.content == "# Hello")
    }

    @Test("longFormContent with draft is kind 30024")
    func longFormDraft() {
        #expect(EventTemplate.longFormContent(LongFormContent(identifier: "d"), draft: true).kind == .longFormDraft)
        #expect(EventTemplate.longFormContent(LongFormContent(identifier: "d"), draft: false).kind == .longFormContent)
    }

    @Test("longFormContent stamps a missing published_at with the current time")
    func longFormPublishedAtDefault() throws {
        let before = Timestamp.now
        let template = EventTemplate.longFormContent(LongFormContent(identifier: "d"))
        let after = Timestamp.now

        let publishedAt = try #require(
            template.tags.first { $0.name == "published_at" }?.primaryValue.flatMap(Int64.init)
        )
        #expect(publishedAt >= before.rawValue && publishedAt <= after.rawValue)
    }
}
