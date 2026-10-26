import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-23 Long Form Content Tests")
struct NIP23LongFormTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    private func makeSigner() throws -> EventSigner {
        EventSigner(keyPair: try KeyPair())
    }

    // MARK: - Tag mapping

    @Test("tags emits d/title/summary/image/published_at/t in order")
    func tagsEmitsAllFields() {
        let article = LongFormContent(
            identifier: "my-article",
            title: "Hello",
            summary: "A summary",
            imageURL: "https://example.com/cover.png",
            publishedAt: Timestamp(rawValue: 1_700_000_000),
            hashtags: ["nostr", "swift"],
            content: "# Body"
        )

        let tags = article.tags
        #expect(tags[0] == ["d", "my-article"])
        #expect(tags.contains(["title", "Hello"]))
        #expect(tags.contains(["summary", "A summary"]))
        #expect(tags.contains(["image", "https://example.com/cover.png"]))
        #expect(tags.contains(["published_at", "1700000000"]))
        #expect(tags.contains(["t", "nostr"]))
        #expect(tags.contains(["t", "swift"]))
    }

    @Test("tags omits optional fields when nil")
    func tagsOmitsOptionalFields() {
        let article = LongFormContent(identifier: "minimal")
        #expect(article.tags == [["d", "minimal"]])
    }

    @Test("init(event:) round-trips the modeled fields")
    func initEventRoundTrips() throws {
        let article = LongFormContent(
            identifier: "round-trip",
            title: "Title",
            summary: "Summary",
            imageURL: "https://example.com/i.png",
            publishedAt: Timestamp(rawValue: 1_699_000_000),
            hashtags: ["a", "b"],
            content: "Body text"
        )
        let event = try makeSigner().signLongFormContent(article)

        let parsed = try #require(LongFormContent(event: event))
        #expect(parsed.identifier == "round-trip")
        #expect(parsed.title == "Title")
        #expect(parsed.summary == "Summary")
        #expect(parsed.imageURL == "https://example.com/i.png")
        #expect(parsed.publishedAt == Timestamp(rawValue: 1_699_000_000))
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

        // The unmodeled tag is emitted by tags.
        #expect(article.tags.contains(["client", "x"]))

        // Parsing the emitted tags back preserves it in additionalTags, not elsewhere.
        let event = Event(
            id: EventID.fixture("id"),
            pubkey: PublicKey(String(repeating: "a", count: 64))!,
            createdAt: Timestamp(rawValue: 1),
            kind: .longFormContent,
            tags: article.tags.map(\.rawArray),
            content: "",
            signature: nil
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
        let before = Timestamp.now
        let event = try makeSigner().signLongFormContent(LongFormContent(identifier: "d"))
        let after = Timestamp.now
        let publishedAt = try #require(LongFormContent(event: event)?.publishedAt)
        #expect(publishedAt >= before)
        #expect(publishedAt <= after)
    }

    @Test("publishedAt is preserved when set")
    func publishedAtPreserved() throws {
        let published = Timestamp(rawValue: 1_650_000_000)
        let event = try makeSigner().signLongFormContent(
            LongFormContent(identifier: "d", publishedAt: published)
        )
        #expect(LongFormContent(event: event)?.publishedAt == published)
        #expect(event.firstTagValue(named: "published_at") == "1650000000")
    }

    // MARK: - naddr

    @Test("a published_at beyond Date's range round-trips exactly")
    func publishedAtBeyondDateRoundTrips() throws {
        let signer = try makeSigner()
        let event = try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey, kind: .longFormContent,
                rawTags: [["d", "d"], ["published_at", "9223372036854775807"]], content: ""))

        let article = try #require(LongFormContent(event: event))
        #expect(article.publishedAt == Timestamp(rawValue: .max))
        #expect(article.tags.contains(["published_at", "9223372036854775807"]))
    }

    @Test("a published_at that is not an integer is ignored")
    func malformedPublishedAtIgnored() throws {
        let signer = try makeSigner()
        let event = try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey, kind: .longFormContent,
                rawTags: [["d", "d"], ["published_at", "1.5e9"]], content: ""))

        #expect(LongFormContent(event: event)?.publishedAt == nil)
    }

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
    private func subscriptionID(fromReqFrame frame: String) throws -> String {
        guard let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let subscriptionID = array[1] as? String
        else {
            throw NostrError.invalidMessageFormat
        }
        return subscriptionID
    }

    private func eventFrame(subscriptionID: String, event: Event) throws -> String {
        let eventDict: [String: Any] = [
            "id": event.id.hex,
            "pubkey": event.pubkey.hex,
            "created_at": event.createdAt.rawValue,
            "kind": event.kind.rawValue,
            "tags": event.tags,
            "content": event.content,
            "sig": event.signature?.hex ?? "",
        ]
        let array: [Any] = ["EVENT", subscriptionID, eventDict]
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
                publishedAt: Timestamp(rawValue: 1_600_000_000)
            )
        )
        // A distinct newer event for the same identifier (later createdAt wins).
        let newerBase = LongFormContent(
            identifier: "same-d",
            title: "New",
            publishedAt: Timestamp(rawValue: 1_600_000_100)
        )
        let newerUnsigned = UnsignedEvent(
            pubkey: signer.publicKey,
            createdAt: Timestamp(rawValue: older.createdAt.rawValue + 1000),
            kind: .longFormContent,
            tags: newerBase.tags,
            content: ""
        )
        let newer = try signer.sign(newerUnsigned)

        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(
                    connectionTimeout: .seconds(1), pingInterval: .seconds(60), autoReconnect: false)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let client = NostrClient(relayPool: pool)
        let connection = await pool.addRelay(relayURL)
        try await connection.connect()

        let task = Task {
            try await client.events.fetchLongFormContent(
                author: signer.publicKey, identifier: "same-d", timeout: .seconds(2))
        }

        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let reqFrame = try #require(mock.sentTextFrames.first { $0.hasPrefix("[\"REQ\"") })
        let receivedID = try subscriptionID(fromReqFrame: reqFrame)

        mock.deliver(.string(try eventFrame(subscriptionID: receivedID, event: older)))
        mock.deliver(.string(try eventFrame(subscriptionID: receivedID, event: newer)))
        mock.deliver(.string("[\"EOSE\",\"\(receivedID)\"]"))

        let result = try await task.value
        #expect(result?.title == "New")
        await client.relays.disconnect()
    }

    @Test("fetchLongFormContent(naddr:) targets the coordinate and returns the article")
    func fetchByNAddr() async throws {
        let signer = try makeSigner()
        let article = LongFormContent(identifier: "coord-d", title: "Coordinated")
        let event = try signer.signLongFormContent(article, draft: false)

        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(
                    connectionTimeout: .seconds(1), pingInterval: .seconds(60), autoReconnect: false)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let client = NostrClient(relayPool: pool)
        let connection = await pool.addRelay(relayURL)
        try await connection.connect()

        // A relay hint matching the pooled relay: the fetch targets it (the new `to:` param).
        let naddr = try article.naddr(author: signer.publicKey, relays: [relayURL])

        let task = Task { try await client.events.fetchLongFormContent(naddr: naddr, timeout: .seconds(2)) }

        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let reqFrame = try #require(mock.sentTextFrames.first { $0.hasPrefix("[\"REQ\"") })
        let receivedID = try subscriptionID(fromReqFrame: reqFrame)

        mock.deliver(.string(try eventFrame(subscriptionID: receivedID, event: event)))
        mock.deliver(.string("[\"EOSE\",\"\(receivedID)\"]"))

        let result = try await task.value
        #expect(result?.title == "Coordinated")
        #expect(result?.identifier == "coord-d")
        await client.relays.disconnect()
    }
}
