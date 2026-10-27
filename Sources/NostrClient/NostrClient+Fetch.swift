import Foundation
import NostrCore

// MARK: - One-time Fetches — actor-isolated internals
//
// The public surface lives on ``NostrEventsAPI``; this is the shared engine every namespace
// that reads stored events (lists, groups, long-form, relay lists) funnels through.
extension NostrClient {
    /// Fetches events matching `filters`, waiting for every targeted relay to send EOSE or for
    /// `timeout`, whichever comes first. Takes pre-validated canonical URLs; nil fetches from
    /// the whole pool. A nil `timeout` resolves to the pool's ``RelayPoolConfig/queryTimeout``
    /// here, so the public wrappers just forward the caller's optional.
    ///
    /// Backs ``NostrEventFetching/fetch(filters:route:timeout:)``.
    func fetch(
        filters: [Filter],
        fromURLs relayURLs: Set<RelayURL>?,
        timeout: Duration?
    ) async throws -> [Event] {
        let timeout = timeout ?? pool.config.queryTimeout
        let subscription = try await pool.subscribe(filters: filters, to: relayURLs)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
            } catch {
                // Cancelled because fetch finished first: nothing to do.
                return
            }
            await subscription.close()
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
}
