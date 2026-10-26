import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// The ``NostrRelayManaging`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows which
/// primitives each one calls, in what order, and with what configuration — without sockets.
@Suite("Relay Capability Tests")
struct RelayCapabilityTests {
    private let relayA = RelayURL("wss://a.example.com")!
    private let relayB = RelayURL("wss://b.example.com")!

    @Test("adding one relay without a configuration asks for the pool's default")
    func addShortFormUsesTheDefaultConfig() async throws {
        let stub = RecordingRelayCapabilities()
        let relays: any NostrRelayManaging = stub

        let connection = await relays.add(relayA)

        #expect(await stub.calls == [.add(relayA, hasConfig: false)])
        #expect(connection.url == relayA)
        #expect(await relays.relay(for: relayA) === connection)
    }

    @Test("adding several relays adds each in order with the pool's default configuration")
    func addSequenceAddsEachRelay() async throws {
        let stub = RecordingRelayCapabilities()
        let relays: any NostrRelayManaging = stub

        // A repeat is forwarded like any other URL; the primitive keeps the existing connection.
        await relays.add([relayA, relayB, relayA])

        #expect(
            await stub.calls == [
                .add(relayA, hasConfig: false), .add(relayB, hasConfig: false), .add(relayA, hasConfig: false),
            ])
        #expect(await stub.configs.isEmpty)
        #expect(await relays.relayCount == 2)
    }

    @Test("adding a lazy sequence of relays consumes it once")
    func addSequenceAcceptsAnySequence() async throws {
        let stub = RecordingRelayCapabilities()
        let relays: any NostrRelayManaging = stub

        await relays.add(["a", "b"].lazy.compactMap { RelayURL("wss://\($0).example.com") })

        #expect(await stub.calls == [.add(relayA, hasConfig: false), .add(relayB, hasConfig: false)])
    }

    @Test("connect(to:) adds every relay, then connects")
    func connectToAddsThenConnects() async throws {
        let stub = RecordingRelayCapabilities()
        let relays: any NostrRelayManaging = stub

        try await relays.connect(to: [relayA, relayB])

        #expect(
            await stub.calls == [.add(relayA, hasConfig: false), .add(relayB, hasConfig: false), .connect])
    }

    @Test("connect(to:) keeps the relays it added when connecting fails, and rethrows the error")
    func connectToRethrowsAfterAdding() async throws {
        let stub = RecordingRelayCapabilities(connectError: .allConnectionsFailed)
        let relays: any NostrRelayManaging = stub

        await #expect(throws: RelayPool.Error.allConnectionsFailed) {
            try await relays.connect(to: [relayA])
        }

        #expect(await stub.calls == [.add(relayA, hasConfig: false), .connect])
        #expect(await relays.relayCount == 1)
    }

    @Test("relayCount counts the pool's connections, connected or not")
    func relayCountCountsConnections() async throws {
        let stub = RecordingRelayCapabilities()
        let relays: any NostrRelayManaging = stub

        #expect(await relays.relayCount == 0)
        await relays.add(relayA)
        await relays.add(relayB, config: RelayConnectionConfig(autoReconnect: false))
        #expect(await relays.relayCount == 2)
        #expect(await relays.connectedRelayCount() == 0)

        await relays.remove(relayA)
        #expect(await relays.relayCount == 1)
        #expect(await relays.relayCount == relays.connections.count)
    }
}
