import Foundation

/// Brings relay URLs into the pool — and, for `.addAndConnect`, connects them —
/// according to a ``GossipRelayPolicy``.
///
/// Shared by the per-pubkey relay-list stores (NIP-65 ``RelayListStore`` and
/// NIP-17 ``DirectMessageRelayListStore``) so they resolve and connect relays
/// the same way.
struct RelayConnector: Sendable {
    private let pool: RelayPool
    private let policy: GossipRelayPolicy

    /// Maximum number of new relays to add+connect for a single resolve call.
    /// Bounds connection growth when routing across many users' relay lists.
    private let maxRelaysPerResolve: Int

    init(pool: RelayPool, policy: GossipRelayPolicy = .addAndConnect, maxRelaysPerResolve: Int = 8) {
        self.pool = pool
        self.policy = policy
        self.maxRelaysPerResolve = maxRelaysPerResolve
    }

    /// Ensures the given relay URLs are present (and, for `.addAndConnect`, connected) in the pool,
    /// honoring the configured policy and per-resolve cap.
    /// - Returns: The subset of URLs available for routing.
    func ensureConnected(_ urls: Set<URL>) async -> Set<URL> {
        var available: Set<URL> = []
        var added = 0
        for url in urls {
            let isPresent = await pool.relay(for: url) != nil
            switch policy {
            case .requirePresent:
                if isPresent {
                    available.insert(url)
                }
            case .addAndConnect:
                if isPresent {
                    available.insert(url)
                } else if added < maxRelaysPerResolve {
                    let connection = await pool.addRelay(url: url)
                    added += 1
                    // Best-effort: a dead outbox/inbox relay must not fail the whole operation.
                    try? await connection.connect()
                    available.insert(url)
                }
            }
        }
        return available
    }
}
