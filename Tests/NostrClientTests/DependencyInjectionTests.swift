import Foundation
import Testing

@testable import NostrClient

/// Exercises the transport seam threaded up through ``RelayPool`` and ``NostrClient``:
/// with an injected fake factory, both layers connect real relay URLs without a network.
@Suite("Dependency Injection Tests")
struct DependencyInjectionTests {

    /// A factory that hands out a fresh socket per connection attempt, so concurrently
    /// connected relays don't share one mock's buffers.
    private func fakeFactory() -> MockWebSocketSessionFactory {
        MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
    }

    private var noReconnectConfig: RelayPoolConfig {
        RelayPoolConfig(
            defaultRelayConfig: RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
        )
    }

    @Test("pool connects its relays through an injected fake transport")
    func poolConnectsThroughFakeTransport() async throws {
        let pool = RelayPool(config: noReconnectConfig, webSocketFactory: fakeFactory())
        await pool.addRelay(url: URL(string: "wss://relay.example.com")!)
        await pool.addRelay(url: URL(string: "wss://relay2.example.com")!)

        let connected = try await pool.connectAll()

        #expect(connected == 2)
        await pool.disconnectAll()
    }

    @Test("client connects through an injected pool without a network")
    func clientConnectsThroughInjectedPool() async throws {
        let pool = RelayPool(config: noReconnectConfig, webSocketFactory: fakeFactory())
        let client = NostrClient(relayPool: pool)

        try await client.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])

        #expect(await client.relayPool.count == 2)
        // connect(to:) only throws when *every* relay fails, so assert both sockets
        // actually reached `.connected` rather than just being registered.
        #expect(await client.relayPool.connectedCount() == 2)
        await client.disconnect()
    }
}
