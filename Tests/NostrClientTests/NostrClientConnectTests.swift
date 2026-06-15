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
        await #expect(throws: NostrError.self) {
            try await client.connect(to: [""])
        }
        #expect(await client.relayPool.count == 0)
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
