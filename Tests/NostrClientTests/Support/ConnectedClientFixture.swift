import Foundation
import NostrCore
import NostrTestSupport

@testable import NostrClient

/// Builds `NostrClient`s backed by a single connected mock relay, for tests whose
/// subscribes and publishes need a live (test-controlled) target in the pool.
enum ConnectedClientFixture {

    /// The relay URL used when the caller does not supply one.
    static let defaultRelayURL = URL(string: "wss://relay.example.com")!

    /// A relay config that fails fast and never reconnects, keeping tests deterministic.
    static var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    /// Returns a client whose pool holds one connected relay at `relayURL`; every
    /// socket the pool opens is the returned mock.
    static func make(
        relayURL: URL = defaultRelayURL,
        gossipPolicy: GossipRelayPolicy = .addAndConnect
    ) async throws -> (client: NostrClient, socket: MockWebSocketSession) {
        let socket = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket })
        )
        let client = NostrClient(relayPool: pool, gossipPolicy: gossipPolicy)
        let connection = await pool.addRelay(url: relayURL)
        try await connection.connect()
        return (client, socket)
    }
}
