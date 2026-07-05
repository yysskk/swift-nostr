import Foundation
import NostrCore

// MARK: - One-time Fetches
extension NostrClient {
    /// Fetches events matching the given filters (one-time)
    /// Waits for all subscribed relays to send EOSE, or until timeout (whichever comes first)
    public func fetch(filters: [Filter], timeout: TimeInterval = 10) async throws -> [Event] {
        let subscription = try await subscribe(filters: filters)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: .seconds(timeout))
                await subscription.close()
            } catch {
                // Cancelled because fetch finished first: nothing to do.
            }
        }
        defer { timeoutTask.cancel() }

        var eoseTracker = EOSETracker()
        eoseTracker.setExpectedRelays(subscription.expectedRelays)

        var events: [Event] = []
        for await item in subscription {
            switch item {
            case .event(_, let event):
                events.append(event)
            case .eose(let relayURL):
                if eoseTracker.recordEOSE(from: relayURL) {
                    await subscription.close()
                }
            default:
                break
            }
        }

        try Task.checkCancellation()
        return events
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT).
    ///
    /// Queries every relay in the pool and returns the maximum reported count — each relay's
    /// count is a lower bound on the events it holds, so the maximum is the best single estimate.
    /// For per-relay results use ``RelayPool/count(filters:to:timeout:)`` on ``relayPool``.
    public func count(filters: [Filter], timeout: TimeInterval = 10) async throws -> Int {
        let results = try await relayPool.count(filters: filters, timeout: timeout)
        return results.values.map(\.value).max() ?? 0
    }

    /// Fetches a single event by ID
    public func fetchEvent(id: String, timeout: TimeInterval = 10) async throws -> Event? {
        let filter = Filter(ids: [id])
        let events = try await fetch(filters: [filter], timeout: timeout)
        return events.first
    }

    /// Fetches user metadata
    public func fetchMetadata(pubkey: String, timeout: TimeInterval = 10) async throws -> UserMetadata? {
        let filter = Filter.metadata(pubkeys: [pubkey])
        let events = try await fetch(filters: [filter], timeout: timeout)

        guard let event = events.first else { return nil }

        return try? JSONDecoder().decode(UserMetadata.self, from: Data(event.content.utf8))
    }
}
