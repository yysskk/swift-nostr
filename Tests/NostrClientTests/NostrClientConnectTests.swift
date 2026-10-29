import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NostrClient Connect Tests")
struct NostrClientConnectTests {

    @Test("connect(to:) with no relays is a no-op")
    func connectToEmptyListIsNoOp() async throws {
        let client = NostrClient()
        try await client.relays.connect(to: [])
        #expect(await client.relays.pool.relayCount == 0)
    }

    @Test("relays.add(_:config:) applies the per-relay configuration")
    func addAppliesConfig() async throws {
        let client = NostrClient()
        let config = RelayConnectionConfig(
            connectionTimeout: .seconds(42), pingInterval: .seconds(60), reconnect: nil)

        let connection = await client.relays.add(RelayURL("wss://relay.example.com")!, config: config)

        #expect(await connection.config.connectionTimeout == .seconds(42))
        #expect(await connection.config.reconnect == nil)
        // The default-config path stays intact for relays added without an override.
        let plain = await client.relays.add(RelayURL("wss://other.example.com")!)
        #expect(await plain.config.connectionTimeout == RelayConnectionConfig.default.connectionTimeout)
    }

    @Test("relays.remove removes via an alternate spelling and ignores absent relays")
    func removeNormalizesAndIgnoresAbsent() async throws {
        let client = NostrClient()
        _ = await client.relays.add(RelayURL("wss://relay.example.com")!)
        #expect(await client.relays.pool.relayCount == 1)

        await client.relays.remove(RelayURL("wss://Relay.Example.com/")!)
        #expect(await client.relays.pool.relayCount == 0)

        // Removing an absent relay is a no-op.
        await client.relays.remove(RelayURL("wss://absent.example.com")!)
        #expect(await client.relays.pool.relayCount == 0)
    }

    @Test("connect(to:) adds the relays and surfaces total connection failure")
    func connectToAddsRelaysAndConnects() async throws {
        // Nothing listens on the loopback discard port; the attempt fails fast
        // and is bounded by the 1-second connection timeout in the worst case.
        let poolConfig = RelayPoolConfig(
            defaultRelayConfig: RelayConnectionConfig(connectionTimeout: .seconds(1), reconnect: nil)
        )
        let client = NostrClient(config: NostrClient.Config(relayPool: poolConfig))

        await #expect(throws: RelayPool.Error.allConnectionsFailed) {
            try await client.relays.connect(to: [RelayURL("ws://127.0.0.1:9")!])
        }
        // The relay was added even though connecting failed.
        #expect(await client.relays.pool.relayCount == 1)
    }
}
