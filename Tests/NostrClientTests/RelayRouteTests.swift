import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// Each ``RelayRoute`` sends a publish, fetch, count, or subscription to the expected relays of a
/// pool holding relays A, B, and C. NIP-65 relay lists are seeded straight into the client's cache,
/// and the ``GossipRelayPolicy/requirePresent`` policy keeps the outbox on the pooled relays.
@Suite("Relay Route Tests")
struct RelayRouteTests {
    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!
    private let unknown = RelayURL("wss://unknown.example.com")!

    // MARK: - Fixtures

    /// A client whose pool holds connected relays A, B, and C, paired with the sockets driving them
    /// in that order. A relay-list lookup the cache cannot answer gives up after 100 ms.
    private func makeClient() async throws -> (client: NostrClient, sockets: [MockWebSocketSession]) {
        let sockets = [MockWebSocketSession(), MockWebSocketSession(), MockWebSocketSession()]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: ConnectedClientFixture.noReconnectConfig, queryTimeout: .milliseconds(100)),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets[counter.next()] })
        )
        for url in [urlA, urlB, urlC] {
            try await pool.addRelay(url).connect()
        }
        return (NostrClient(relayPool: pool, gossipPolicy: .requirePresent), sockets)
    }

    /// Caches `publicKey`'s NIP-65 relay list as if it had been fetched.
    private func seedRelayList(
        _ client: NostrClient, for publicKey: PublicKey, read: [RelayURL] = [], write: [RelayURL] = []
    ) async {
        await client.relayListStore.store(
            RelayListMetadata(read: read, write: write), createdAt: Timestamp(rawValue: 1_700_000_000),
            for: publicKey)
    }

    /// The indexes of the sockets that sent a frame of `type` ("EVENT", "REQ", or "COUNT") whose
    /// payload is not a relay-list lookup.
    private func sockets(
        _ sockets: [MockWebSocketSession], thatSent type: String
    ) -> Set<Int> {
        let indexes = sockets.indices.filter { index in
            sockets[index].sentTextFrames.contains {
                $0.hasPrefix("[\"\(type)\"") && !$0.contains("\"kinds\":[\(Event.Kind.relayListMetadata.rawValue)]")
            }
        }
        return Set(indexes)
    }

    /// The subscription id of the first COUNT frame `socket` sent.
    private func countSubscriptionID(in socket: MockWebSocketSession) throws -> String {
        let frame = try #require(socket.sentTextFrames.first { $0.hasPrefix("[\"COUNT\"") })
        let array = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [Any])
        return try #require(array[1] as? String)
    }

    // MARK: - Publish

    @Test("publishing along .pool reaches every pooled relay")
    func publishPool() async throws {
        let (client, sockets) = try await makeClient()
        let event = EventSigner(keyPair: KeyPair()).sign(.textNote("everywhere"))

        let task = Task { try await client.events.publish(event, route: .pool, strategy: .allSettled) }
        for socket in sockets {
            try await PublishAckSupport.acknowledgePublish(on: socket)
        }

        #expect(try await task.value.acceptedRelays == [urlA, urlB, urlC])
        await client.relays.disconnect()
    }

    @Test("publishing along .outbox reaches the author's WRITE relays and the mentions' READ relays")
    func publishOutbox() async throws {
        let (client, sockets) = try await makeClient()
        let author = KeyPair()
        let mention = PublicKey.fixture("mention")
        try await client.identity.setPrivateKey(author.privateKey.hex)
        await seedRelayList(client, for: author.publicKey, read: [urlC], write: [urlA])
        await seedRelayList(client, for: mention, read: [urlB], write: [urlC])

        let task = Task {
            try await client.events.publish(
                .textNote("hi", tags: [.publicKey(mention)]), route: .outbox, strategy: .allSettled)
        }
        try await PublishAckSupport.acknowledgePublish(on: sockets[0])
        try await PublishAckSupport.acknowledgePublish(on: sockets[1])
        let published = try await task.value

        #expect(published.result.acceptedRelays == [urlA, urlB])
        // The author's READ relay and the mention's WRITE relay are not outbox targets.
        #expect(PublishAckSupport.eventFrames(in: sockets[2]).isEmpty)
        await client.relays.disconnect()
    }

    @Test("publishing along .outbox falls back to the whole pool when no relay list resolves")
    func publishOutboxFallsBackToPool() async throws {
        let (client, sockets) = try await makeClient()
        let event = EventSigner(keyPair: KeyPair()).sign(.textNote("unrouted"))

        // The author's relay list is looked up first and never arrives.
        let task = Task { try await client.events.publish(event, route: .outbox, strategy: .allSettled) }
        for socket in sockets {
            try await PublishAckSupport.acknowledgePublish(on: socket)
        }

        #expect(try await task.value.acceptedRelays == [urlA, urlB, urlC])
        await client.relays.disconnect()
    }

    // MARK: - Fetch and count

    @Test("fetching along each route queries the expected relays")
    func fetchRoutes() async throws {
        let (client, sockets) = try await makeClient()
        let author = PublicKey.fixture("author")
        await seedRelayList(client, for: author, read: [urlA], write: [urlC])
        let filter = Filter(authors: [author], kinds: [.textNote])

        _ = try await client.events.fetch(filters: [filter], route: .outbox, timeout: .milliseconds(100))
        #expect(self.sockets(sockets, thatSent: "REQ") == [2])

        _ = try await client.events.fetch(filters: [filter], route: .relays([urlB]), timeout: .milliseconds(100))
        #expect(self.sockets(sockets, thatSent: "REQ") == [1, 2])

        _ = try await client.events.fetch(filters: [filter], route: .pool, timeout: .milliseconds(100))
        #expect(self.sockets(sockets, thatSent: "REQ") == [0, 1, 2])
        await client.relays.disconnect()
    }

    @Test("counting along .outbox asks only the authors' WRITE relays")
    func countOutbox() async throws {
        let (client, sockets) = try await makeClient()
        let author = PublicKey.fixture("author")
        await seedRelayList(client, for: author, write: [urlB])

        let task = Task {
            try await client.events.countEvents(
                matching: [Filter(authors: [author], kinds: [.textNote])], route: .outbox)
        }
        try await NIP42TestSupport.pollUntil { sockets[1].sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") } }
        let subscriptionID = try countSubscriptionID(in: sockets[1])
        sockets[1].deliver(.string("[\"COUNT\",\"\(subscriptionID)\",{\"count\":7}]"))

        #expect(try await task.value == 7)
        #expect(self.sockets(sockets, thatSent: "COUNT") == [1])
        await client.relays.disconnect()
    }

    // MARK: - Subscribe

    @Test("subscribing along each route opens on the expected relays")
    func subscribeRoutes() async throws {
        let (client, sockets) = try await makeClient()
        let alice = PublicKey.fixture("alice")
        let bob = PublicKey.fixture("bob")
        await seedRelayList(client, for: alice, read: [urlC], write: [urlA])
        await seedRelayList(client, for: bob, write: [urlB])
        let filter = Filter(authors: [alice, bob], kinds: [.textNote])

        let outbox = try await client.subscriptions.subscribe(filters: [filter], route: .outbox)
        #expect(self.sockets(sockets, thatSent: "REQ") == [0, 1])
        let targeted = try await client.subscriptions.subscribe(filters: [filter], route: .relays([urlC]))
        let pooled = try await client.subscriptions.subscribe(filters: [filter])

        #expect(outbox.expectedRelays == [urlA, urlB])
        #expect(targeted.expectedRelays == [urlC])
        #expect(pooled.expectedRelays == [urlA, urlB, urlC])
        for subscription in [outbox, targeted, pooled] {
            await subscription.close()
        }
        await client.relays.disconnect()
    }

    @Test("a read along .outbox falls back to the whole pool when an author or a filter is unrouted")
    func readOutboxFallsBackToPool() async throws {
        let (client, _) = try await makeClient()
        let routed = PublicKey.fixture("routed")
        await seedRelayList(client, for: routed, write: [urlA])

        // The second author's relay list is looked up and never arrives.
        let unresolvedAuthor = try await client.subscriptions.subscribe(
            filters: [Filter(authors: [routed, PublicKey.fixture("unknown")])], route: .outbox)
        // A filter without authors can match anyone.
        let authorless = try await client.subscriptions.subscribe(
            filters: [Filter(authors: [routed]), Filter(kinds: [.textNote])], route: .outbox)

        #expect(unresolvedAuthor.expectedRelays == [urlA, urlB, urlC])
        #expect(authorless.expectedRelays == [urlA, urlB, urlC])
        await unresolvedAuthor.close()
        await authorless.close()
        await client.relays.disconnect()
    }

    // MARK: - Relays not in the pool

    @Test("reading along .relays outside the pool throws noMatchingRelays without sending anything")
    func readRelaysOutsidePoolThrow() async throws {
        let (client, sockets) = try await makeClient()
        let filter = Filter(kinds: [.textNote])

        await #expect(throws: RelayPool.Error.noMatchingRelays([unknown])) {
            try await client.events.fetch(filters: [filter], route: .relays([self.unknown]))
        }
        await #expect(throws: RelayPool.Error.noMatchingRelays([unknown])) {
            try await client.events.countEvents(matching: [filter], route: .relays([self.unknown]))
        }
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            try await client.subscriptions.subscribe(filters: [filter], route: .relays([]))
        }
        #expect(sockets.allSatisfy { $0.sentTextFrames.allSatisfy { !$0.hasPrefix("[\"REQ\"") } })
        #expect(sockets.allSatisfy { $0.sentTextFrames.allSatisfy { !$0.hasPrefix("[\"COUNT\"") } })
        #expect(await client.relays.relayCount == 3)
        await client.relays.disconnect()
    }
}

/// Hands out incrementing indexes to a factory closure that must stay `@Sendable`.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
