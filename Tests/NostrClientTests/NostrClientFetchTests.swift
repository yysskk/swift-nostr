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
        let relay1 = URL(string: "wss://relay1.example")!
        let relay2 = URL(string: "wss://relay2.example")!

        #expect(tracker.setExpectedRelays([relay1, relay2]) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.isComplete == false)
        #expect(tracker.recordEOSE(from: relay2) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("EOSE tracker handles early EOSE before relay count is known")
    func eoseTrackerHandlesEarlyEOSE() {
        var tracker = EOSETracker()
        let relay = URL(string: "wss://relay.example")!

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
        let relay1 = URL(string: "wss://relay1.example")!
        let relay2 = URL(string: "wss://relay2.example")!

        #expect(tracker.setExpectedRelays([relay1, relay2]) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.recordEOSE(from: relay1) == false)
        #expect(tracker.isComplete == false)
        #expect(tracker.recordEOSE(from: relay2) == true)
        #expect(tracker.isComplete == true)
    }

    @Test("Fetch validates target strings before touching any relay")
    func fetchRejectsInvalidTargetString() async throws {
        let client = NostrClient()

        // Validation precedes targeting, so the invalid string wins over the empty pool.
        await #expect(throws: NostrError.invalidRelayURL("https://relay.example.com")) {
            _ = try await client.fetch(filters: [Filter()], to: ["https://relay.example.com"])
        }
    }

    @Test("Fetch on an empty pool throws noRelaysInPool immediately")
    func fetchOnEmptyPoolThrows() async throws {
        let client = NostrClient()

        // The throw happens at subscribe time, before the timeout task could ever
        // start — assert it does not consume the (long) timeout.
        let start = ContinuousClock.now
        await #expect(throws: NostrError.noRelaysInPool) {
            _ = try await client.fetch(filters: [Filter()], timeout: 10)
        }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test("Fetch propagates task cancellation")
    func fetchPropagatesTaskCancellation() async throws {
        // One connected mock relay that never sends EOSE, so the fetch blocks
        // on its subscription until the task is cancelled.
        let (client, _) = try await ConnectedClientFixture.make()

        let fetchTask = Task {
            try await client.fetch(filters: [Filter()], timeout: 10)
        }

        try await Task.sleep(for: .milliseconds(100))
        fetchTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await fetchTask.value
        }
        await client.disconnect()
    }
}
