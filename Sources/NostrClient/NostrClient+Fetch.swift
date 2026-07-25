import Foundation
import NostrCore

// MARK: - One-time Fetches
extension NostrClient {
    /// Fetches events matching the given filters (one-time)
    /// Waits for all subscribed relays to send EOSE, or until timeout (whichever comes first).
    ///
    /// Pass relay URL strings to scope the fetch to a subset of relays (e.g. `naddr` relay
    /// hints); the default `nil` fetches from all relays in the pool. Targets de-duplicate
    /// by their normalized routing key; an empty array always throws.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` for an invalid target string, and
    ///   ``NostrError/noRelaysInPool`` or ``NostrError/noMatchingRelays(_:)``
    ///   (via the underlying subscribe) when nothing can be targeted.
    public func fetch(
        filters: [Filter],
        to relayURLs: [String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> [Event] {
        try await fetch(filters: filters, toURLs: relayURLs.map(RelayURL.requireTargets), timeout: timeout)
    }

    /// Core of ``fetch(filters:to:timeout:)`` taking pre-validated canonical URLs;
    /// nil fetches from the whole pool.
    func fetch(
        filters: [Filter],
        toURLs relayURLs: Set<URL>?,
        timeout: TimeInterval
    ) async throws -> [Event] {
        let subscription = try await subscribe(filters: filters, toURLs: relayURLs)

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
        if eoseTracker.setExpectedRelays(subscription.expectedRelays) {
            await subscription.close()
        }

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
    /// Queries the targeted relays and returns the maximum reported count — each relay's
    /// count is a lower bound on the events it holds, so the maximum is the best single estimate.
    /// `relayURLs` is nil (the default) to query the whole pool, or relay URL strings to
    /// target a subset; an empty array always throws. For per-relay results use
    /// ``RelayPool/count(filters:to:timeout:)`` on ``relayPool``.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` for an invalid target string,
    ///   ``NostrError/noRelaysInPool`` when the pool is empty, or
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool.
    public func count(
        filters: [Filter],
        to relayURLs: [String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Int {
        let results = try await relayPool.count(
            filters: filters,
            toURLs: relayURLs.map(RelayURL.requireTargets),
            timeout: timeout
        )
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
