import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Relay Pool Routing Tests (NIP-65)")
struct RelayPoolRoutingTests {

    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!
    private let unknown = RelayURL("wss://unknown.example.com")!

    private var dummyEvent: Event {
        Event(
            id: EventID(String(repeating: "a", count: 64))!,
            publicKey: PublicKey(String(repeating: "b", count: 64))!,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            tags: [],
            content: "test",
            signature: Signature(String(repeating: "c", count: 128))!
        )
    }

    private func makePool() async throws -> RelayPool {
        let pool = RelayPool()
        await pool.add(urlA)
        await pool.add(urlB)
        await pool.add(urlC)
        return pool
    }

    // MARK: - Target resolution

    @Test("targetConnections(nil) returns all relays")
    func targetAllWhenNil() async throws {
        let pool = try await makePool()
        let count = try await pool.targetConnections(nil).count
        #expect(count == 3)
    }

    @Test("targetConnections(nil) on an empty pool throws emptyPool")
    func targetNilOnEmptyPoolThrows() async {
        let pool = RelayPool()
        await #expect(throws: RelayPool.Error.emptyPool) {
            _ = try await pool.targetConnections(nil)
        }
    }

    @Test("targetConnections with a subset returns only those relays")
    func targetSubset() async throws {
        let pool = try await makePool()
        let connections = try await pool.targetConnections([urlA, urlB])
        #expect(connections.count == 2)
    }

    @Test("targetConnections with a partially-unknown set keeps only present relays")
    func targetPartialUnknown() async throws {
        let pool = try await makePool()
        let connections = try await pool.targetConnections([urlA, unknown])
        #expect(connections.count == 1)
        #expect(connections.first?.url == urlA)
    }

    @Test("targetConnections with only unknown URLs throws noMatchingRelays")
    func targetUnknownThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: RelayPool.Error.noMatchingRelays([self.unknown])) {
            _ = try await pool.targetConnections([unknown])
        }
    }

    @Test("targetConnections with an empty set throws noMatchingRelays")
    func targetEmptyThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            _ = try await pool.targetConnections([])
        }
    }

    @Test("noMatchingRelays carries the de-duplicated targets sorted by their canonical form")
    func noMatchingRelaysPayload() async throws {
        let pool = try await makePool()
        // Two spellings of the same unknown relay plus another unknown one.
        let targets: Set<RelayURL> = [
            RelayURL("wss://Unknown.Example.com/")!,
            RelayURL("wss://unknown.example.com")!,
            RelayURL("wss://also-unknown.example.com")!,
        ]
        await #expect(
            throws: RelayPool.Error.noMatchingRelays([
                RelayURL("wss://also-unknown.example.com")!,
                RelayURL("wss://unknown.example.com")!,
            ])
        ) {
            _ = try await pool.targetConnections(targets)
        }
    }

    @Test("targetConnections resolves targets spelled differently from the pool key")
    func targetViaAlternateSpelling() async throws {
        let pool = try await makePool()
        let connections = try await pool.targetConnections([RelayURL("wss://A.Example.com/")!])
        #expect(connections.count == 1)
        #expect(connections.first?.url == urlA)
    }

    @Test("publishing to only-unknown targets throws noMatchingRelays")
    func publishToUnknownTargetsThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: RelayPool.Error.noMatchingRelays([self.unknown])) {
            try await pool.publish(self.dummyEvent, to: [self.unknown])
        }
    }

    // MARK: - Canonical pool keys

    @Test("add dedupes alternate spellings of the same relay")
    func addDedupesSpellings() async throws {
        let pool = RelayPool()
        let first = await pool.add(RelayURL("wss://Relay.Example.com/")!)
        let second = await pool.add(RelayURL("wss://relay.example.com")!)
        let third = await pool.add(RelayURL("wss://relay.example.com:443")!)

        #expect(await pool.relayCount == 1)
        #expect(first === second)
        #expect(second === third)
        #expect(first.url == RelayURL("wss://relay.example.com")!)
    }

    @Test("add(_:) with a sequence adds each relay once and keeps existing connections")
    func addSequenceAddsEachRelayOnce() async throws {
        let pool = RelayPool()
        let existing = await pool.add(urlA)

        await pool.add([RelayURL("wss://A.example.com/")!, urlB, urlC, urlB])

        #expect(await pool.relayCount == 3)
        #expect(await pool.relay(for: urlA) === existing)
        #expect(await pool.relay(for: urlB) != nil)
        #expect(await pool.relay(for: urlC) != nil)
    }

    @Test("relay(for:) and remove resolve alternate spellings")
    func lookupAndRemoveViaAlternateSpelling() async throws {
        let pool = RelayPool()
        let added = await pool.add(RelayURL("wss://relay.example.com")!)

        #expect(await pool.relay(for: RelayURL("wss://Relay.Example.com/")!) === added)
        await pool.remove(RelayURL("wss://RELAY.EXAMPLE.COM")!)
        #expect(await pool.relayCount == 0)
    }

    @Test("remove then re-adding under another spelling yields a fresh connection")
    func removeThenReAddYieldsFreshConnection() async throws {
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        )
        let first = await pool.add(RelayURL("wss://relay.example.com")!)
        try await first.connect()

        await pool.remove(RelayURL("wss://relay.example.com")!)
        let second = await pool.add(RelayURL("wss://Relay.Example.com/")!)

        #expect(await pool.relayCount == 1)
        #expect(first !== second)
        await pool.disconnect()
    }

    @Test("publish statuses are keyed by the canonical relay URL")
    func publishStatusesKeyedByCanonicalURL() async throws {
        let socket = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket })
        )
        let canonical = RelayURL("wss://relay.example.com")!
        let connection = await pool.add(RelayURL("wss://Relay.Example.com/")!)
        try await connection.connect()

        // Target the relay under yet another spelling; the result reports the canonical key.
        let result = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await pool.publish(self.dummyEvent, to: [RelayURL("wss://RELAY.example.com")!])
        }
        #expect(result.acceptedRelays == [canonical])
        #expect(result.status(for: RelayURL("wss://Relay.Example.com/")!) == .accepted)
        await pool.disconnect()
    }

    // MARK: - Subscribe failure cleanup

    @Test("a subscribe that fails on every relay leaves no subscription state")
    func subscribeTotalFailureCleansUp() async throws {
        // Sockets whose keepalive ping fails make every connection attempt fail
        // deterministically, so each REQ send (which auto-connects) errors out.
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(
                    connectionTimeout: .milliseconds(200), pingInterval: .seconds(60), reconnect: nil)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: {
                MockWebSocketSession(pingError: URLError(.cannotConnectToHost))
            })
        )
        await pool.add(urlA)
        await pool.add(urlB)

        await #expect(throws: RelayPool.Error.subscriptionFailed) {
            try await pool.subscribe(filters: [Filter()])
        }
        #expect(await pool.subscriptionCount == 0)
    }

    // MARK: - Pool lookups

    @Test("relay(for:) finds present and absent relays")
    func relayLookup() async throws {
        let pool = try await makePool()
        let present = await pool.relay(for: urlA)
        let absent = await pool.relay(for: unknown)
        #expect(present != nil)
        #expect(absent == nil)
    }

    @Test("relayCount reflects added relays")
    func poolRelayCount() async throws {
        let pool = try await makePool()
        let count = await pool.relayCount
        #expect(count == 3)
    }
}
