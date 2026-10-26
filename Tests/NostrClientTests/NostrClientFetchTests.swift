import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NostrClient Fetch Tests")
struct NostrClientFetchTests {

    @Test("EOSE tracker waits for every expected relay")
    func eoseTrackerWaitsForEveryExpectedRelay() {
        var tracker = EOSETracker()
        let relay1 = RelayURL("wss://relay1.example")!
        let relay2 = RelayURL("wss://relay2.example")!

        #expect(tracker.setExpectedRelays([relay1, relay2]) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.isComplete == false)
        #expect(tracker.recordEOSE(from: relay2) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("EOSE tracker handles early EOSE before relay count is known")
    func eoseTrackerHandlesEarlyEOSE() {
        var tracker = EOSETracker()
        let relay = RelayURL("wss://relay.example")!

        #expect(tracker.recordEOSE(from: relay) == false)
        #expect(tracker.isComplete == false)
        #expect(tracker.setExpectedRelays([relay]) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("EOSE tracker treats an empty expected set as vacuously complete")
    func eoseTrackerEmptyExpectedSetIsComplete() {
        var tracker = EOSETracker()

        // Not complete while the expected set is unknown...
        #expect(tracker.isComplete == false)
        // ...but complete once it is known to be empty: nothing can send EOSE.
        #expect(tracker.setExpectedRelays([]) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("EOSE tracker ignores duplicate relay EOSE")
    func eoseTrackerIgnoresDuplicateRelayEOSE() {
        var tracker = EOSETracker()
        let relay1 = RelayURL("wss://relay1.example")!
        let relay2 = RelayURL("wss://relay2.example")!

        #expect(tracker.setExpectedRelays([relay1, relay2]) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.isComplete == false)
        #expect(tracker.recordEOSE(from: relay2) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("Fetch on an empty pool throws emptyPool immediately")
    func fetchOnEmptyPoolThrows() async throws {
        let client = NostrClient()

        // The throw happens at subscribe time, before the timeout task could ever
        // start — assert it does not consume the (long) timeout.
        let start = ContinuousClock.now
        await #expect(throws: RelayPool.Error.emptyPool) {
            _ = try await client.events.fetch(filters: [Filter()], timeout: .seconds(10))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("Fetch propagates task cancellation")
    func fetchPropagatesTaskCancellation() async throws {
        // One connected mock relay that never sends EOSE, so the fetch blocks
        // on its subscription until the task is cancelled.
        let (client, _) = try await ConnectedClientFixture.make()

        let fetchTask = Task {
            try await client.events.fetch(filters: [Filter()], timeout: .seconds(10))
        }

        try await Task.sleep(for: .milliseconds(100))
        fetchTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await fetchTask.value
        }
        await client.relays.disconnect()
    }

    // MARK: - Query timeout

    /// A client whose pool holds one connected mock relay that never sends EOSE, with the given
    /// pool-wide query timeout.
    private func makeSilentRelayClient(queryTimeout: Duration) async throws -> NostrClient {
        let socket = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: ConnectedClientFixture.noReconnectConfig,
                queryTimeout: queryTimeout
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket })
        )
        let client = NostrClient(relayPool: pool)
        let connection = await pool.addRelay(ConnectedClientFixture.defaultRelayURL)
        try await connection.connect()
        return client
    }

    @Test("Fetch without a timeout ends after the pool's queryTimeout")
    func fetchWithoutTimeoutUsesQueryTimeout() async throws {
        let client = try await makeSilentRelayClient(queryTimeout: .milliseconds(50))

        let start = ContinuousClock.now
        let events = try await client.events.fetch(filters: [Filter()])
        let elapsed = ContinuousClock.now - start

        #expect(events.isEmpty)
        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .seconds(5))
        await client.relays.disconnect()
    }

    @Test("An explicit fetch timeout overrides a longer queryTimeout")
    func explicitFetchTimeoutOverridesLongerQueryTimeout() async throws {
        let client = try await makeSilentRelayClient(queryTimeout: .seconds(30))

        let start = ContinuousClock.now
        let events = try await client.events.fetch(filters: [Filter()], timeout: .milliseconds(50))

        #expect(events.isEmpty)
        #expect(ContinuousClock.now - start < .seconds(5))
        await client.relays.disconnect()
    }

    @Test("An explicit fetch timeout overrides a shorter queryTimeout")
    func explicitFetchTimeoutOverridesShorterQueryTimeout() async throws {
        let client = try await makeSilentRelayClient(queryTimeout: .milliseconds(20))

        let start = ContinuousClock.now
        let events = try await client.events.fetch(filters: [Filter()], timeout: .milliseconds(300))
        let elapsed = ContinuousClock.now - start

        #expect(events.isEmpty)
        #expect(elapsed >= .milliseconds(250))
        #expect(elapsed < .seconds(5))
        await client.relays.disconnect()
    }
}
