import Foundation

/// Policy controlling how the outbox/gossip router brings relays into the pool
/// when routing to a user's NIP-65 read/write relays.
public enum GossipRelayPolicy: Sendable {
    /// Add resolved relays to the pool and connect them on demand (default).
    case addAndConnect
    /// Only route to relays already present in the pool; never open new sockets.
    case requirePresent
}

/// Caches per-pubkey NIP-65 relay lists and resolves outbox/inbox relay sets for the gossip model.
/// Owned by `NostrClient`; holds a reference to the shared `RelayPool`.
actor RelayListStore {
    private let pool: RelayPool
    private let policy: GossipRelayPolicy

    /// Maximum number of new relays this store will add+connect for a single resolve call.
    /// Bounds connection growth when routing across many users' relay lists.
    private let maxRelaysPerResolve: Int

    /// pubkey -> (relay list, createdAt of the event it came from)
    private var cache: [String: (list: RelayListMetadata, createdAt: Int64)] = [:]

    init(pool: RelayPool, policy: GossipRelayPolicy = .addAndConnect, maxRelaysPerResolve: Int = 8) {
        self.pool = pool
        self.policy = policy
        self.maxRelaysPerResolve = maxRelaysPerResolve
    }

    /// Stores a relay list if it is newer than the cached one (replaceable-event semantics: newer wins).
    /// An equal `createdAt` keeps the existing entry.
    /// - Returns: The effective (possibly pre-existing) list.
    @discardableResult
    func store(_ list: RelayListMetadata, createdAt: Int64, for pubkey: String) -> RelayListMetadata {
        if let existing = cache[pubkey], existing.createdAt >= createdAt {
            return existing.list
        }
        cache[pubkey] = (list, createdAt)
        return list
    }

    /// Ingests a kind 10002 event into the cache.
    /// - Returns: The effective list, or nil if the event is not a relay list metadata event.
    @discardableResult
    func ingest(_ event: Event) -> RelayListMetadata? {
        guard let list = event.relayListMetadata else {
            return nil
        }
        return store(list, createdAt: event.createdAt, for: event.pubkey)
    }

    /// Returns the cached relay list for a pubkey, if any.
    func cachedList(for pubkey: String) -> RelayListMetadata? {
        cache[pubkey]?.list
    }

    /// Resolves the WRITE relays for a pubkey (where the user publishes) — use these to READ their events.
    func writeRelayURLs(for pubkey: String) -> Set<URL> {
        urlSet(cache[pubkey]?.list.writeRelays ?? [])
    }

    /// Resolves the READ relays for a pubkey (their inbox) — use these to SEND them events they should see.
    func readRelayURLs(for pubkey: String) -> Set<URL> {
        urlSet(cache[pubkey]?.list.readRelays ?? [])
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

    private func urlSet(_ strings: [String]) -> Set<URL> {
        Set(strings.compactMap { URL(string: RelayListMetadata.normalize($0)) })
    }
}
