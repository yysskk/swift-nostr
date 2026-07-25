import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NostrClient Connect Tests")
struct NostrClientConnectTests {

    @Test("connect(to:) with no relays is a no-op")
    func connectToEmptyListIsNoOp() async throws {
        let client = NostrClient()
        try await client.connect(to: [])
        #expect(await client.relayPool.count == 0)
    }

    @Test("connect(to:) rejects invalid relay URLs before connecting")
    func connectToRejectsInvalidURLs() async throws {
        let client = NostrClient()
        await #expect(throws: NostrError.invalidRelayURL("")) {
            try await client.connect(to: [""])
        }
        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            try await client.connect(to: ["https://relay.example.com"])
        }
        #expect(await client.relayPool.count == 0)
    }

    @Test("addRelay(_:config:) applies the per-relay configuration")
    func addRelayAppliesConfig() async throws {
        let client = NostrClient()
        let config = RelayConnectionConfig(connectionTimeout: 42, pingInterval: 60, autoReconnect: false)

        let connection = try await client.addRelay("wss://relay.example.com", config: config)

        #expect(await connection.config.connectionTimeout == 42)
        #expect(await connection.config.autoReconnect == false)
        // The default-config path stays intact for relays added without an override.
        let plain = try await client.addRelay("wss://other.example.com")
        #expect(await plain.config.connectionTimeout == RelayConnectionConfig.default.connectionTimeout)
    }

    @Test("removeRelay removes via an alternate spelling and ignores absent relays")
    func removeRelayNormalizesAndIgnoresAbsent() async throws {
        let client = NostrClient()
        _ = try await client.addRelay("wss://relay.example.com")
        #expect(await client.relayPool.count == 1)

        try await client.removeRelay("wss://Relay.Example.com/")
        #expect(await client.relayPool.count == 0)

        // Removing a valid but absent relay is a no-op.
        try await client.removeRelay("wss://absent.example.com")
        #expect(await client.relayPool.count == 0)
    }

    @Test("removeRelay throws invalidRelayURL for a non-relay URL")
    func removeRelayRejectsInvalidURL() async throws {
        let client = NostrClient()
        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            try await client.removeRelay("https://relay.example.com")
        }
    }

    @Test("connect(to:) adds the relays and surfaces total connection failure")
    func connectToAddsRelaysAndConnects() async throws {
        // Nothing listens on the loopback discard port; the attempt fails fast
        // and is bounded by the 1-second connection timeout in the worst case.
        let poolConfig = RelayPoolConfig(
            defaultRelayConfig: RelayConnectionConfig(connectionTimeout: 1, autoReconnect: false)
        )
        let client = NostrClient(relayPoolConfig: poolConfig)

        await #expect(throws: NostrError.self) {
            try await client.connect(to: ["ws://127.0.0.1:9"])
        }
        // The relay was added even though connecting failed.
        #expect(await client.relayPool.count == 1)
    }
}
