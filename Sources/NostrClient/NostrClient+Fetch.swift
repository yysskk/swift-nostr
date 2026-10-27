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
            // Closing ends the stream, so fetch returns and cancels this task while the CLOSE frames
            // are still being sent — and a cancelled send counts as a failed one, which drops the
            // connection. The close therefore runs in a task of its own.
            await Task { await subscription.close() }.value
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
