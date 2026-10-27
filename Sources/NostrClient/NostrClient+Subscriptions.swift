import Foundation
import NostrCore

// MARK: - Subscriptions
//
// The public surface lives on ``NostrSubscriptionsAPI``, which forwards to the ``RelayPool``: the
// pool generates each subscription's id and owns the sequence it feeds, so the client keeps no
// subscription state of its own.
extension NostrClient {
    /// The number of open subscriptions (for tests).
    var activeSubscriptionCount: Int {
        get async { await pool.subscriptionCount }
    }
}
