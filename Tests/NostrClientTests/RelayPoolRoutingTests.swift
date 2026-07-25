import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Relay Pool Routing Tests (NIP-65)")
struct RelayPoolRoutingTests {

    private let urlA = URL(string: "wss://a.example.com")!
    private let urlB = URL(string: "wss://b.example.com")!
    private let urlC = URL(string: "wss://c.example.com")!
    private let unknown = URL(string: "wss://unknown.example.com")!

    private var dummyEvent: Event {
        Event(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "test",
            sig: String(repeating: "c", count: 128)
        )
    }

    private func makePool() async throws -> RelayPool {
        let pool = RelayPool()
        try await pool.addRelay(urlA)
        try await pool.addRelay(urlB)
        try await pool.addRelay(urlC)
        return pool
    }

    // MARK: - Target resolution

    @Test("targetConnections(nil) returns all relays")
    func targetAllWhenNil() async throws {
        let pool = try await makePool()
        let count = try await pool.targetConnections(nil).count
        #expect(count == 3)
    }

    @Test("targetConnections(nil) on an empty pool throws noRelaysInPool")
    func targetNilOnEmptyPoolThrows() async {
        let pool = RelayPool()
        await #expect(throws: NostrError.noRelaysInPool) {
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
        await #expect(throws: NostrError.noMatchingRelays(["wss://unknown.example.com"])) {
            _ = try await pool.targetConnections([unknown])
        }
    }

    @Test("targetConnections with an empty set throws noMatchingRelays")
    func targetEmptyThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: NostrError.noMatchingRelays([])) {
            _ = try await pool.targetConnections([])
        }
    }

    @Test("noMatchingRelays carries the normalized, de-duplicated, sorted URLs")
    func noMatchingRelaysPayload() async throws {
        let pool = try await makePool()
        // Two spellings of the same unknown relay plus another unknown one.
        let targets: Set<URL> = [
            URL(string: "wss://Unknown.Example.com/")!,
            URL(string: "wss://unknown.example.com")!,
            URL(string: "wss://also-unknown.example.com")!,
        ]
        await #expect(
            throws: NostrError.noMatchingRelays([
                "wss://also-unknown.example.com",
                "wss://unknown.example.com",
            ])
        ) {
            _ = try await pool.targetConnections(targets)
        }
    }

    @Test("targetConnections resolves targets spelled differently from the pool key")
    func targetViaAlternateSpelling() async throws {
        let pool = try await makePool()
        let connections = try await pool.targetConnections([URL(string: "wss://A.Example.com/")!])
        #expect(connections.count == 1)
        #expect(connections.first?.url == urlA)
    }

    @Test("publishing to only-unknown string targets throws noMatchingRelays")
    func publishToUnknownStringTargetsThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: NostrError.noMatchingRelays(["wss://unknown.example.com"])) {
            try await pool.publish(self.dummyEvent, to: ["wss://unknown.example.com"])
        }
    }

    @Test("targeting an invalid relay URL string throws invalidRelayURL")
    func targetingInvalidStringThrows() async throws {
        let pool = try await makePool()

        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            try await pool.publish(self.dummyEvent, to: ["https://relay.example.com"])
        }
        await #expect(throws: NostrError.invalidRelayURL("wss:garbage")) {
            try await pool.subscribe(subscriptionId: "sub", filters: [Filter()], to: ["wss:garbage"]) { _ in }
        }
        await #expect(throws: NostrError.invalidRelayURL("wss://user:pw@relay.example.com")) {
            _ = try await pool.count(filters: [Filter()], to: ["wss://user:pw@relay.example.com"])
        }
        // Validation happens before any relay work, so nothing was registered.
        #expect(await pool.subscriptionHandlerCount == 0)
    }

    @Test("addRelay and removeRelay reject non-relay URLs")
    func addAndRemoveRejectInvalidURLs() async throws {
        let pool = RelayPool()

        await #expect(throws: NostrError.invalidRelayURL("wss:garbage")) {
            _ = try await pool.addRelay("wss:garbage")
        }
        // The URL form validates too: a parseable but non-WebSocket URL is refused.
        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            _ = try await pool.addRelay(URL(string: "https://relay.example.com")!)
        }
        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            try await pool.removeRelay("https://relay.example.com")
        }
        #expect(await pool.count == 0)
    }

    // MARK: - Canonical pool keys

    @Test("addRelay dedupes alternate spellings of the same relay")
    func addRelayDedupesSpellings() async throws {
        let pool = RelayPool()
        let first = try await pool.addRelay(URL(string: "wss://Relay.Example.com/")!)
        let second = try await pool.addRelay(URL(string: "wss://relay.example.com")!)
        let third = try await pool.addRelay(URL(string: "wss://relay.example.com:443")!)

        #expect(await pool.count == 1)
        #expect(first === second)
        #expect(second === third)
        #expect(first.url == URL(string: "wss://relay.example.com")!)
    }

    @Test("relay(for:) and removeRelay resolve alternate spellings")
    func lookupAndRemoveViaAlternateSpelling() async throws {
        let pool = RelayPool()
        let added = try await pool.addRelay(URL(string: "wss://relay.example.com")!)

        #expect(await pool.relay(for: URL(string: "wss://Relay.Example.com/")!) === added)
        await pool.removeRelay(URL(string: "wss://RELAY.EXAMPLE.COM")!)
        #expect(await pool.count == 0)
    }

    @Test("removeRelay then re-adding under another spelling yields a fresh connection")
    func removeThenReAddYieldsFreshConnection() async throws {
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        )
        let first = try await pool.addRelay(URL(string: "wss://relay.example.com")!)
        try await first.connect()

        await pool.removeRelay(URL(string: "wss://relay.example.com")!)
        let second = try await pool.addRelay(URL(string: "wss://Relay.Example.com/")!)

        #expect(await pool.count == 1)
        #expect(first !== second)
        await pool.disconnectAll()
    }

    @Test("publish statuses are keyed by the canonical relay URL")
    func publishStatusesKeyedByCanonicalURL() async throws {
        let socket = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket })
        )
        let canonical = URL(string: "wss://relay.example.com")!
        let connection = try await pool.addRelay(URL(string: "wss://Relay.Example.com/")!)
        try await connection.connect()

        // Target the relay under yet another spelling; the result reports the canonical key.
        let result = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await pool.publish(self.dummyEvent, to: ["wss://RELAY.example.com"])
        }
        #expect(result.acceptedRelays == [canonical])
        #expect(result.status(for: "wss://Relay.Example.com/") == .accepted)
        await pool.disconnectAll()
    }

    // MARK: - Subscribe failure cleanup

    @Test("a subscribe that fails on every relay leaves no handler or listener state")
    func subscribeTotalFailureCleansUp() async throws {
        // Sockets whose keepalive ping fails make every connection attempt fail
        // deterministically, so each REQ send (which auto-connects) errors out.
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(
                    connectionTimeout: 0.2, pingInterval: 60, autoReconnect: false)
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: {
                MockWebSocketSession(pingError: URLError(.cannotConnectToHost))
            })
        )
        try await pool.addRelay(urlA)
        try await pool.addRelay(urlB)

        await #expect(throws: NostrError.relayError("Failed to subscribe on any relay")) {
            try await pool.subscribe(subscriptionId: "sub", filters: [Filter()]) { _ in }
        }
        #expect(await pool.subscriptionHandlerCount == 0)
        #expect(await pool.subscriptionTaskCount == 0)
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

    @Test("count reflects added relays")
    func poolCount() async throws {
        let pool = try await makePool()
        let count = await pool.count
        #expect(count == 3)
    }
}
