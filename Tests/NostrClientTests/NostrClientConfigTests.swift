import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// ``NostrClient/Config`` defaults, and how ``NostrClient/Config/maximumGossipRelaysPerResolve``
/// bounds the relays one gossip resolution adds to the pool and connects.
@Suite("NostrClient Config Tests")
struct NostrClientConfigTests {
    /// More declared relays than the limits under test, so the cap is what decides the outcome.
    private static let declaredRelays = (1...5).map { RelayURL("wss://relay\($0).example.com")! }

    /// A client built through the public initializer whose sockets come from a fake factory.
    private func makeClient(maximumGossipRelaysPerResolve: Int) -> NostrClient {
        let relayConfig = RelayConnectionConfig(
            connectionTimeout: .seconds(1), pingInterval: .seconds(60), reconnect: nil)
        let config = NostrClient.Config(
            relayPool: RelayPoolConfig(defaultRelayConfig: relayConfig),
            maximumGossipRelaysPerResolve: maximumGossipRelaysPerResolve
        )
        let factory = MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        return NostrClient(config: config, webSocketFactory: factory)
    }

    @Test("Config.default adds and connects at most 8 gossip relays over the default pool")
    func defaultValues() {
        let config = NostrClient.Config.default
        #expect(config.gossipPolicy == .addAndConnect)
        #expect(config.maximumGossipRelaysPerResolve == 8)
        #expect(config.relayPool.queryTimeout == RelayPoolConfig.default.queryTimeout)
        #expect(config.relayPool.defaultPublishStrategy == RelayPoolConfig.default.defaultPublishStrategy)
    }

    @Test("client exposes the configuration it was created with")
    func clientExposesConfig() async {
        let poolConfig = RelayPoolConfig(queryTimeout: .seconds(3))
        let config = NostrClient.Config(
            relayPool: poolConfig, gossipPolicy: .requirePresent, maximumGossipRelaysPerResolve: 3)

        let client = NostrClient(config: config)

        #expect(client.config.gossipPolicy == .requirePresent)
        #expect(client.config.maximumGossipRelaysPerResolve == 3)
        #expect(client.config.relayPool.queryTimeout == .seconds(3))
        #expect(await client.relays.pool.config.queryTimeout == .seconds(3))
    }

    @Test(
        "an outbox read adds and connects at most maximumGossipRelaysPerResolve relays",
        arguments: [
            (limit: 2, expected: 2), (limit: 8, expected: 5), (limit: 0, expected: 0), (limit: -1, expected: 0),
        ]
    )
    func outboxReadHonorsLimit(limit: Int, expected: Int) async throws {
        let client = makeClient(maximumGossipRelaysPerResolve: limit)
        let author = PublicKey.fixture("author")
        let relayList = RelayListMetadata(read: [], write: Self.declaredRelays)
        await client.relayListStore.store(relayList, createdAt: Timestamp(rawValue: 1_700_000_000), for: author)
        let filters = [Filter(authors: [author], kinds: [.textNote])]

        let targets = await client.routing.relayURLs(reading: filters, along: .outbox)

        // With nothing added there is nothing to route to, so the read falls back to the pool.
        #expect(targets?.count ?? 0 == expected)
        #expect(await client.relays.pool.relayCount == expected)
        #expect(await client.relays.pool.connectedRelayCount() == expected)
        await client.relays.disconnect()
    }

    @Test(
        "a DM inbox resolution adds and connects at most maximumGossipRelaysPerResolve relays",
        arguments: [(limit: 2, expected: 2), (limit: 0, expected: 0)]
    )
    func inboxResolutionHonorsLimit(limit: Int, expected: Int) async throws {
        let client = makeClient(maximumGossipRelaysPerResolve: limit)
        let recipient = PublicKey.fixture("recipient")
        let inboxList = DirectMessageRelayList(relays: Self.declaredRelays)
        await client.dmRelayListStore.store(inboxList, createdAt: Timestamp(rawValue: 1_700_000_000), for: recipient)

        let inboxRelays = await client.routing.connectedInboxRelays(for: recipient)

        #expect(inboxRelays.count == expected)
        #expect(inboxRelays.isSubset(of: Set(Self.declaredRelays)))
        #expect(await client.relays.pool.relayCount == expected)
        #expect(await client.relays.pool.connectedRelayCount() == expected)
        await client.relays.disconnect()
    }

    @Test("a zero limit still routes to declared relays already in the pool")
    func zeroLimitUsesPooledRelays() async throws {
        let client = makeClient(maximumGossipRelaysPerResolve: 0)
        let pooled = Self.declaredRelays[0]
        try await client.relays.connect(to: [pooled])
        let author = PublicKey.fixture("author")
        let relayList = RelayListMetadata(read: [], write: Self.declaredRelays)
        await client.relayListStore.store(relayList, createdAt: Timestamp(rawValue: 1_700_000_000), for: author)
        let filters = [Filter(authors: [author], kinds: [.textNote])]

        let targets = await client.routing.relayURLs(reading: filters, along: .outbox)

        #expect(targets == [pooled])
        #expect(await client.relays.pool.relayCount == 1)
        await client.relays.disconnect()
    }
}
