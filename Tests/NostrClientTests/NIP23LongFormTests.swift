import Foundation
import NostrCore
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-23 Long Form Content Tests")
struct NIP23LongFormTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeSigner() throws -> EventSigner {
        EventSigner(keyPair: try KeyPair())
    }

    // MARK: - Tag mapping

    @Test("toTags emits d/title/summary/image/published_at/t in order")
    func toTagsEmitsAllFields() {
        let article = LongFormContent(
            identifier: "my-article",
            title: "Hello",
            summary: "A summary",
            imageURL: "https://example.com/cover.png",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            hashtags: ["nostr", "swift"],
            content: "# Body"
        )

        let tags = article.toTags()
        #expect(tags[0] == ["d", "my-article"])
        #expect(tags.contains(["title", "Hello"]))
        #expect(tags.contains(["summary", "A summary"]))
        #expect(tags.contains(["image", "https://example.com/cover.png"]))
        #expect(tags.contains(["published_at", "1700000000"]))
        #expect(tags.contains(["t", "nostr"]))
        #expect(tags.contains(["t", "swift"]))
    }

    @Test("toTags omits optional fields when nil")
    func toTagsOmitsOptionalFields() {
        let article = LongFormContent(identifier: "minimal")
        #expect(article.toTags() == [["d", "minimal"]])
    }

    @Test("init(event:) round-trips the modeled fields")
    func initEventRoundTrips() throws {
        let article = LongFormContent(
            identifier: "round-trip",
            title: "Title",
            summary: "Summary",
            imageURL: "https://example.com/i.png",
            publishedAt: Date(timeIntervalSince1970: 1_699_000_000),
            hashtags: ["a", "b"],
            content: "Body text"
        )
        let event = try makeSigner().signLongFormContent(article)

        let parsed = try #require(LongFormContent(event: event))
        #expect(parsed.identifier == "round-trip")
        #expect(parsed.title == "Title")
        #expect(parsed.summary == "Summary")
        #expect(parsed.imageURL == "https://example.com/i.png")
        #expect(parsed.publishedAt == Date(timeIntervalSince1970: 1_699_000_000))
        #expect(parsed.hashtags == ["a", "b"])
        #expect(parsed.content == "Body text")
    }

    @Test("Unmodeled tags land in additionalTags and survive a round-trip")
    func unmodeledTagsAreLossless() {
        let article = LongFormContent(
            identifier: "lossless",
            title: "Kept",
            additionalTags: [["client", "x"]]
        )

        // The unmodeled tag is emitted by toTags().
        #expect(article.toTags().contains(["client", "x"]))

        // Parsing the emitted tags back preserves it in additionalTags, not elsewhere.
        let event = Event(
            id: "id",
            pubkey: String(repeating: "a", count: 64),
            createdAt: 1,
            kind: .longFormContent,
            tags: article.toTags(),
            content: "",
            sig: ""
        )
        let parsed = LongFormContent(event: event)
        #expect(parsed?.additionalTags == [["client", "x"]])
        #expect(parsed?.title == "Kept")
    }

    // MARK: - Kind

    @Test("longFormDraft is kind 30024 and addressable")
    func draftKindIsAddressable() {
        #expect(Event.Kind.longFormDraft.rawValue == 30024)
        #expect(Event.Kind.longFormDraft.isAddressable)
    }

    // MARK: - Signing

    @Test("signLongFormContent(draft: true) signs a kind 30024 event")
    func signDraftKind() throws {
        let event = try makeSigner().signLongFormContent(LongFormContent(identifier: "d"), draft: true)
        #expect(event.kind == .longFormDraft)
        #expect(try event.verify())
    }

    @Test("signLongFormContent(draft: false) signs a kind 30023 event")
    func signArticleKind() throws {
        let event = try makeSigner().signLongFormContent(LongFormContent(identifier: "d"), draft: false)
        #expect(event.kind == .longFormContent)
        #expect(try event.verify())
    }

    @Test("publishedAt is auto-filled when nil")
    func publishedAtAutoFilled() throws {
        let event = try makeSigner().signLongFormContent(LongFormContent(identifier: "d"))
        let publishedTag: Event.Tag? = event.tags(named: "published_at").first
        #expect(publishedTag != nil)
        #expect(LongFormContent(event: event)?.publishedAt != nil)
    }

    @Test("publishedAt is preserved when set")
    func publishedAtPreserved() throws {
        let published = Date(timeIntervalSince1970: 1_650_000_000)
        let event = try makeSigner().signLongFormContent(
            LongFormContent(identifier: "d", publishedAt: published)
        )
        #expect(LongFormContent(event: event)?.publishedAt == published)
        #expect(event.firstTagValue(named: "published_at") == "1650000000")
    }

    // MARK: - naddr

    @Test("naddr round-trips through bech32 and matches NAddr(event:)")
    func naddrRoundTrips() throws {
        let signer = try makeSigner()
        let article = LongFormContent(identifier: "addressable-id")
        let event = try signer.signLongFormContent(article, draft: false)

        let naddr = try article.naddr(author: signer.publicKey)
        let decoded = try NAddr(bech32String: naddr.encoded)
        #expect(decoded.identifier == "addressable-id")
        #expect(decoded.author == signer.publicKey)
        #expect(decoded.kind == Event.Kind.longFormContent.rawValue)

        let fromEvent = try NAddr(event: event)
        #expect(decoded.identifier == fromEvent.identifier)
        #expect(decoded.author == fromEvent.author)
        #expect(decoded.kind == fromEvent.kind)
    }

    // MARK: - Event convenience

    @Test("Event.longFormContent is non-nil for an article and nil for a text note")
    func eventLongFormContentProperty() throws {
        let signer = try makeSigner()
        let article = try signer.signLongFormContent(LongFormContent(identifier: "d", title: "T"))
        #expect(article.longFormContent?.title == "T")

        let note = try signer.signTextNote(content: "hi")
        #expect(note.longFormContent == nil)
    }

    @Test("init(event:) returns nil for a non-article kind")
    func initEventNilForOtherKind() throws {
        let note = try makeSigner().signTextNote(content: "hi")
        #expect(LongFormContent(event: note) == nil)
    }

    // MARK: - Client fetch (mock relay)

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// Reads the generated subscription id from a sent REQ frame.
    private func subscriptionId(fromReqFrame frame: String) throws -> String {
        guard let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let subscriptionId = array[1] as? String
        else {
            throw NostrError.invalidMessageFormat
        }
        return subscriptionId
    }

    private func eventFrame(subscriptionId: String, event: Event) throws -> String {
        let eventDict: [String: Any] = [
            "id": event.id,
            "pubkey": event.pubkey,
            "created_at": event.createdAt,
            "kind": event.kind.rawValue,
            "tags": event.tags,
            "content": event.content,
            "sig": event.sig,
        ]
        let array: [Any] = ["EVENT", subscriptionId, eventDict]
        let data = try JSONSerialization.data(withJSONObject: array)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("fetchLongFormContent(author:identifier:) keeps the newest version across relays")
    func fetchNewestWins() async throws {
        let signer = try makeSigner()
        let older = try signer.signLongFormContent(
            LongFormContent(
                identifier: "same-d",
                title: "Old",
                publishedAt: Date(timeIntervalSince1970: 1_600_000_000)
            )
        )
        // A distinct newer event for the same identifier (later createdAt wins).
        let newerBase = LongFormContent(
            identifier: "same-d",
            title: "New",
            publishedAt: Date(timeIntervalSince1970: 1_600_000_100)
        )
        let newerUnsigned = UnsignedEvent(
            pubkey: signer.publicKey,
            createdAt: older.createdAt + 1000,
            kind: .longFormContent,
            rawTags: newerBase.toTags(),
            content: ""
        )
        let newer = try signer.sign(newerUnsigned)

        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let client = NostrClient(relayPool: pool)
        let connection = await pool.addRelay(url: relayURL)
        try await connection.connect()

        let task = Task {
            try await client.fetchLongFormContent(author: signer.publicKey, identifier: "same-d", timeout: 2)
        }

        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let reqFrame = try #require(mock.sentTextFrames.first { $0.hasPrefix("[\"REQ\"") })
        let subId = try subscriptionId(fromReqFrame: reqFrame)

        mock.deliver(.string(try eventFrame(subscriptionId: subId, event: older)))
        mock.deliver(.string(try eventFrame(subscriptionId: subId, event: newer)))
        mock.deliver(.string("[\"EOSE\",\"\(subId)\"]"))

        let result = try await task.value
        #expect(result?.title == "New")
        await client.disconnect()
    }

    @Test("fetchLongFormContent(naddr:) targets the coordinate and returns the article")
    func fetchByNAddr() async throws {
        let signer = try makeSigner()
        let article = LongFormContent(identifier: "coord-d", title: "Coordinated")
        let event = try signer.signLongFormContent(article, draft: false)

        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let client = NostrClient(relayPool: pool)
        let connection = await pool.addRelay(url: relayURL)
        try await connection.connect()

        // A relay hint matching the pooled relay: the fetch targets it (the new `to:` param).
        let naddr = try article.naddr(author: signer.publicKey, relays: [relayURL.absoluteString])

        let task = Task { try await client.fetchLongFormContent(naddr: naddr, timeout: 2) }

        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let reqFrame = try #require(mock.sentTextFrames.first { $0.hasPrefix("[\"REQ\"") })
        let subId = try subscriptionId(fromReqFrame: reqFrame)

        mock.deliver(.string(try eventFrame(subscriptionId: subId, event: event)))
        mock.deliver(.string("[\"EOSE\",\"\(subId)\"]"))

        let result = try await task.value
        #expect(result?.title == "Coordinated")
        #expect(result?.identifier == "coord-d")
        await client.disconnect()
    }
}
