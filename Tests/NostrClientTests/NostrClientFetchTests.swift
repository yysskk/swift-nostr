import Foundation
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

    @Test("Fetch propagates task cancellation")
    func fetchPropagatesTaskCancellation() async throws {
        let client = NostrClient()

        let fetchTask = Task {
            try await client.fetch(filters: [Filter()], timeout: 10)
        }

        try await Task.sleep(for: .milliseconds(100))
        fetchTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await fetchTask.value
        }
    }
}
