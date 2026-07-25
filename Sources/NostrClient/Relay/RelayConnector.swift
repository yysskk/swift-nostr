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
    /// - Returns: The subset of URLs available for routing, in their canonical (normalized)
    ///   form regardless of the input spelling.
    func ensureConnected(_ urls: Set<URL>) async -> Set<URL> {
        var available: Set<URL> = []
        var added = 0
        for url in urls {
            if let present = await pool.relay(for: url) {
                available.insert(present.url)
                continue
            }
            guard policy == .addAndConnect, added < maxRelaysPerResolve else { continue }
            // Relay lists are third-party data; an entry the pool refuses must not sink
            // the whole route — urlSet's filtering makes this a second line of defense.
            guard let connection = try? await pool.addRelay(url) else { continue }
            added += 1
            // Best-effort: a dead outbox/inbox relay must not fail the whole operation.
            try? await connection.connect()
            available.insert(connection.url)
        }
        return available
    }
}
