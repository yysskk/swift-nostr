import Foundation
import NostrClient
import NostrCore
import NostrTestSupport
import Testing

// This file imports NostrClient without `@testable`, so it sees only what a module outside the
// package sees. It mirrors the "Extending the Client" article: a helper added to an existing
// capability, and a namespace composed of capabilities with a `NostrClient` accessor.

// MARK: - A helper on an existing capability

/// The NIP-38 user status kind.
private let userStatusKind = Event.Kind(rawValue: 30315)

extension NostrEventPublishing {
    /// Signs and publishes a NIP-38 general user status (kind 30315) to the whole pool.
    @discardableResult
    fileprivate func publishStatus(
        _ status: String,
        expiration: Timestamp? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        var template = EventTemplate(kind: userStatusKind, tags: [.identifier("general")], content: status)
        if let expiration {
            template.tags.append(.expiration(expiration))
        }
        return try await publish(template, strategy: strategy)
    }
}

// MARK: - A namespace composed of capabilities

/// NIP-57 zaps, built from the capabilities they need rather than from the client.
private struct ZapsAPI: Sendable {
    let events: any NostrEventFetching
    let identity: any NostrIdentityProviding

    /// Signs a zap request to send to the recipient's LNURL-pay callback.
    func signRequest(
        to recipient: PublicKey,
        amountMillisats: Int64,
        relays: [RelayURL],
        comment: String = ""
    ) async throws -> Event {
        try await identity.sign(
            .zapRequest(to: recipient, relays: relays, amountMillisats: amountMillisats, comment: comment))
    }

    /// Fetches the zap receipts naming the signer as recipient.
    func received(limit: Int = 50, timeout: Duration? = nil) async throws -> [ZapReceipt] {
        guard let publicKey = await identity.publicKey else { throw NostrClient.Error.signerNotSet }
        let filter = Filter(kinds: [.zap], publicKeyReferences: [publicKey], limit: limit)
        return try await events.fetch(filters: [filter], timeout: timeout).compactMap(ZapReceipt.init(event:))
    }
}

extension NostrClient {
    fileprivate nonisolated var zaps: ZapsAPI { ZapsAPI(events: events, identity: identity) }
}

// MARK: - A stub implementing only the primitives

/// Answers every fetch with canned events and records the filters it was asked for.
private actor CannedEvents: NostrEventFetching {
    let events: [Event]
    private(set) var requests: [[Filter]] = []

    init(_ events: [Event]) { self.events = events }

    func fetch(filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> [Event] {
        requests.append(filters)
        return events
    }

    func countEvents(matching filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> Int
    {
        events.count
    }
}

// MARK: - Tests

/// Extensions written outside the module work on the client, on any conformer, and on stubs that
/// implement only the primitives.
@Suite("Extending the Client Tests")
struct ExtendingTheClientTests {
    private let relayURL = RelayURL("wss://relay.example.com")!

    /// A kind-9735 receipt paying `recipient`, signed by a provider key, whose embedded zap request
    /// carries `amountMillisats`.
    private func makeReceipt(paying recipient: PublicKey, amountMillisats: Int64) throws -> Event {
        let sender = EventSigner(keyPair: KeyPair())
        let request = try sender.sign(
            .zapRequest(to: recipient, relays: [relayURL], amountMillisats: amountMillisats))
        let description = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let provider = EventSigner(keyPair: KeyPair())
        return provider.sign(
            EventTemplate(
                kind: .zap,
                tags: [
                    .publicKey(recipient),
                    Event.Tag(name: "bolt11", values: ["lnbc210n1"]),
                    Event.Tag(name: "description", values: [description]),
                ]
            )
        )
    }

    /// The subscription id and first filter of the first REQ frame sent on `socket`.
    private func sentREQ(in socket: MockWebSocketSession) throws -> (subscriptionID: String, filter: [String: Any]) {
        guard let frame = socket.sentTextFrames.first(where: { $0.hasPrefix("[\"REQ\"") }),
            let array = try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [Any],
            array.count >= 3,
            let subscriptionID = array[1] as? String,
            let filter = array[2] as? [String: Any]
        else {
            throw RelayMessage.Error.malformed
        }
        return (subscriptionID, filter)
    }

    // MARK: - Capability helper

    @Test("a helper on NostrEventPublishing signs and publishes through client.events")
    func capabilityHelperOnClient() async throws {
        let (client, socket) = try await ConnectedClientFixture.make(relayURL: relayURL)
        let signer = EventSigner(keyPair: KeyPair())
        await client.identity.setSigner(signer)
        let expiration = Timestamp.now.advanced(by: .seconds(3600))

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishStatus("Reading NIP-38", expiration: expiration)
        }
        let sent = try PublishAckSupport.event(inFrame: PublishAckSupport.eventFrames(in: socket)[0])

        #expect(sent == published.event)
        #expect(sent.kind == userStatusKind)
        #expect(sent.content == "Reading NIP-38")
        #expect(sent.tags.map(\.rawArray) == [["d", "general"], ["expiration", expiration.description]])
        #expect(sent.publicKey == signer.publicKey)
        #expect(try sent.verify())
        #expect(published.result.statuses[relayURL] == .accepted)
        await client.relays.disconnect()
    }

    @Test("a helper on NostrEventPublishing reaches a primitives-only stub through the existential")
    func capabilityHelperOnStub() async throws {
        let stub = RecordingEventCapabilities(signer: EventSigner(keyPair: KeyPair()))
        let publishing: any NostrEventPublishing = stub

        try await publishing.publishStatus("Away")
        try await publishing.publishStatus("Back soon", strategy: .allSettled)

        let publishes = await stub.templatePublishes
        #expect(publishes.count == 2)
        #expect(publishes[0].template.kind == userStatusKind)
        #expect(publishes[0].template.content == "Away")
        #expect(publishes[0].template.tags == [.identifier("general")])
        #expect(publishes[0].relayURLs == nil)
        #expect(publishes[0].strategy == nil)
        #expect(publishes[1].template.content == "Back soon")
        #expect(publishes[1].strategy == .allSettled)
    }

    // MARK: - Composed namespace

    @Test("a composed namespace signs through client.identity")
    func namespaceSignsThroughClient() async throws {
        let client = NostrClient()
        let signer = EventSigner(keyPair: KeyPair())
        await client.identity.setSigner(signer)
        let recipient = KeyPair().publicKey

        let request = try await client.zaps.signRequest(
            to: recipient, amountMillisats: 21_000, relays: [relayURL], comment: "thanks")

        #expect(request.kind == .zapRequest)
        #expect(request.publicKey == signer.publicKey)
        #expect(request.content == "thanks")
        #expect(request.firstTagValue(named: "p") == recipient.hex)
        #expect(request.firstTagValue(named: "amount") == "21000")
        #expect(try request.verify())
    }

    @Test("a composed namespace fetches through client.events for client.identity's key")
    func namespaceFetchesThroughClient() async throws {
        let (client, socket) = try await ConnectedClientFixture.make(relayURL: relayURL)
        let signer = EventSigner(keyPair: KeyPair())
        await client.identity.setSigner(signer)
        let receipt = try makeReceipt(paying: signer.publicKey, amountMillisats: 21_000)

        let task = Task { try await client.zaps.received(limit: 10) }
        try await NIP42TestSupport.pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let (subscriptionID, filter) = try sentREQ(in: socket)
        let receiptJSON = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
        socket.deliver(.string("[\"EVENT\",\"\(subscriptionID)\",\(receiptJSON)]"))
        socket.deliver(.string("[\"EOSE\",\"\(subscriptionID)\"]"))
        let receipts = try await task.value

        #expect(filter["kinds"] as? [Int] == [Event.Kind.zap.rawValue])
        #expect(filter["#p"] as? [String] == [signer.publicKey.hex])
        #expect(filter["limit"] as? Int == 10)
        #expect(receipts.map(\.event) == [receipt])
        #expect(receipts.first?.amountMillisats == 21_000)
        await client.relays.disconnect()
    }

    @Test("a composed namespace runs against primitives-only stubs")
    func namespaceAgainstStubs() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let receipt = try makeReceipt(paying: signer.publicKey, amountMillisats: 5_000)
        let events = RecordingEventCapabilities(signer: signer, cannedEvents: [receipt])
        let identity = RecordingIdentityCapabilities()
        await identity.setSigner(signer)
        let zaps = ZapsAPI(events: events, identity: identity)

        let receipts = try await zaps.received()

        let fetches = await events.fetches
        #expect(fetches.count == 1)
        #expect(fetches[0].filters == [Filter(kinds: [.zap], publicKeyReferences: [signer.publicKey], limit: 50)])
        #expect(fetches[0].relayURLs == nil)
        #expect(fetches[0].timeout == nil)
        #expect(receipts.first?.amountMillisats == 5_000)
    }

    @Test("a composed namespace mixes a minimal stub with the client's own identity")
    func namespaceWithMinimalStubAndClientIdentity() async throws {
        let client = NostrClient()
        let signer = EventSigner(keyPair: KeyPair())
        await client.identity.setSigner(signer)
        let receipt = try makeReceipt(paying: signer.publicKey, amountMillisats: 21_000)
        let events = CannedEvents([receipt])
        let zaps = ZapsAPI(events: events, identity: client.identity)

        let receipts = try await zaps.received()

        #expect(receipts.map(\.amountMillisats) == [21_000])
        #expect(await events.requests == [[Filter(kinds: [.zap], publicKeyReferences: [signer.publicKey], limit: 50)]])
    }

    @Test("a composed namespace throws signerNotSet before fetching when no signer is set")
    func namespaceWithoutSignerThrows() async throws {
        let events = CannedEvents([])
        let zaps = ZapsAPI(events: events, identity: RecordingIdentityCapabilities())

        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await zaps.received()
        }
        #expect(await events.requests.isEmpty)
    }
}
