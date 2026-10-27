import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("EventTemplate NostrClient Factory Tests")
struct EventTemplateClientTests {
    private func note() throws -> Event {
        EventSigner(keyPair: KeyPair()).sign(.textNote("reported"))
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

    // MARK: - Direct messages

    @Test("directMessage is kind 14 naming the recipient, with the text as content")
    func directMessage() {
        let template = EventTemplate.directMessage("hello", to: .fixture("bob"))

        #expect(template.kind == .privateDirectMessage)
        #expect(template.tags.map(\.rawArray) == [["p", PublicKey.fixture("bob").hex]])
        #expect(template.content == "hello")
    }

    @Test("directMessage appends the subject, then the reply-marked e tag")
    func directMessageSubjectAndReply() {
        let template = EventTemplate.directMessage(
            "re: plans", to: .fixture("bob"), subject: "plans", replyTo: .fixture("parent"))

        #expect(
            template.tags.map(\.rawArray) == [
                ["p", PublicKey.fixture("bob").hex],
                ["subject", "plans"],
                ["e", EventID.fixture("parent").hex, "", "reply"],
            ])
    }

    @Test("directMessageReaction is kind 7 referencing the message, its author, and kind 14")
    func directMessageReaction() {
        let template = EventTemplate.directMessageReaction(to: .fixture("message"), author: .fixture("alice"))

        #expect(template.kind == .reaction)
        #expect(
            template.tags.map(\.rawArray) == [
                ["e", EventID.fixture("message").hex],
                ["p", PublicKey.fixture("alice").hex],
                ["k", "14"],
            ])
        #expect(template.content == "+")
        #expect(
            EventTemplate.directMessageReaction(to: .fixture("message"), author: .fixture("alice"), content: "🤙")
                .content == "🤙")
    }

    @Test("fileMessage is kind 15 with the URL as content and every attachment field as a tag, in order")
    func fileMessage() throws {
        let file = EncryptedFile.encrypt(Data("file bytes".utf8))
        let url = try #require(URL(string: "https://files.example.com/blob"))
        let attachment = FileAttachment(
            url: url, mimeType: "image/png", encryption: file, size: 1024, dimensions: "640x480",
            blurhash: "LEHV6nWB2yk8")

        let template = EventTemplate.fileMessage(attachment, to: .fixture("bob"))

        #expect(template.kind == .fileMessage)
        #expect(template.content == "https://files.example.com/blob")
        #expect(
            template.tags.map(\.rawArray) == [
                ["p", PublicKey.fixture("bob").hex],
                ["file-type", "image/png"],
                ["encryption-algorithm", "aes-gcm"],
                ["decryption-key", file.key.base64EncodedString()],
                ["decryption-nonce", file.nonce.base64EncodedString()],
                ["x", file.encryptedSHA256],
                ["ox", file.originalSHA256],
                ["size", "1024"],
                ["dim", "640x480"],
                ["blurhash", "LEHV6nWB2yk8"],
            ])
    }

    @Test("fileMessage omits the optional tags an attachment leaves nil")
    func fileMessageOmitsNilTags() throws {
        let url = try #require(URL(string: "https://files.example.com/blob"))
        let key = Data(repeating: 1, count: 32)
        let nonce = Data(repeating: 2, count: 12)
        let attachment = FileAttachment(url: url, decryptionKey: key, decryptionNonce: nonce)

        let template = EventTemplate.fileMessage(attachment, to: .fixture("bob"))

        #expect(
            template.tags.map(\.rawArray) == [
                ["p", PublicKey.fixture("bob").hex],
                ["encryption-algorithm", "aes-gcm"],
                ["decryption-key", key.base64EncodedString()],
                ["decryption-nonce", nonce.base64EncodedString()],
            ])
    }

    @Test("DirectMessageBuilder's rumors are the factories' templates under the sender's key")
    func builderRumorsMatchFactories() async throws {
        let alice = KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let file = EncryptedFile.encrypt(Data("file bytes".utf8))
        let url = try #require(URL(string: "https://files.example.com/blob"))
        let attachment = FileAttachment(url: url, mimeType: "image/jpeg", encryption: file)
        let expected: [EventTemplate] = [
            .directMessage("hi", to: .fixture("bob"), subject: "s", replyTo: .fixture("parent")),
            .directMessageReaction(to: .fixture("message"), author: .fixture("bob"), content: "-"),
            .fileMessage(attachment, to: .fixture("bob")),
        ]

        let rumors = [
            try await builder.createMessageWithSelfCopy(
                content: "hi", to: .fixture("bob"), subject: "s", replyTo: .fixture("parent")
            ).rumor,
            try await builder.createReactionWithSelfCopy(
                reaction: "-", to: .fixture("message"), author: .fixture("bob"), recipientPublicKey: .fixture("bob")
            ).rumor,
            try await builder.createFileMessageWithSelfCopy(attachment, to: .fixture("bob")).rumor,
        ]

        #expect(rumors.map(\.kind) == expected.map(\.kind))
        #expect(rumors.map(\.tags) == expected.map(\.tags))
        #expect(rumors.map(\.content) == expected.map(\.content))
        #expect(rumors.allSatisfy { $0.publicKey == alice.publicKey && $0.signature == nil })
    }
}
