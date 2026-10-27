import Foundation
import NostrCore

/// Policy controlling how the router brings relays into the pool when routing to a
/// user's declared relays — NIP-65 read/write relays or NIP-17 DM inbox relays.
public enum GossipRelayPolicy: Sendable, Equatable {
    /// Add resolved relays to the pool and connect them on demand (default).
    case addAndConnect
    /// Only route to relays already present in the pool; never open new sockets.
    case requirePresent
}

/// Caches per-public-key NIP-65 relay lists and resolves outbox/inbox relay sets for the gossip model.
/// Owned by `NostrClient`; routes through the shared `RelayPool` via a ``RelayConnector``.
actor RelayListStore {
    private var cache = ReplaceableCache<RelayListMetadata>()
    /// Public keys a lookup confirmed have no kind 10002 event. This negative cache lets outbox
    /// routing skip a repeat network fetch on every publish or read involving such a key.
    private var resolvedWithoutList: Set<PublicKey> = []
    private let connector: RelayConnector

    init(pool: RelayPool, policy: GossipRelayPolicy = .addAndConnect, maximumRelaysPerResolve: Int = 8) {
        self.connector = RelayConnector(pool: pool, policy: policy, maximumRelaysPerResolve: maximumRelaysPerResolve)
    }

    /// Stores a relay list if it is newer than the cached one (replaceable-event semantics: newer wins).
    /// An equal `createdAt` keeps the existing entry.
    /// - Returns: The effective (possibly pre-existing) list.
    @discardableResult
    func store(_ list: RelayListMetadata, createdAt: Timestamp, for publicKey: PublicKey) -> RelayListMetadata {
        // A real list supersedes any earlier "no list" result for this public key.
        resolvedWithoutList.remove(publicKey)
        return cache.store(list, createdAt: createdAt, for: publicKey)
    }

    /// Records that a network lookup found no relay list for `publicKey`, so repeated
    /// resolutions can skip the fetch. A later kind 10002 (via ``store(_:createdAt:for:)``
    /// or ``ingest(_:)``) clears the mark.
    func markNoList(for publicKey: PublicKey) {
        resolvedWithoutList.insert(publicKey)
    }

    /// Whether this public key's relay list has already been resolved — either a list is
    /// cached, or a lookup confirmed there is none — so another network fetch can be skipped.
    func isResolved(for publicKey: PublicKey) -> Bool {
        cache.value(for: publicKey) != nil || resolvedWithoutList.contains(publicKey)
    }

    /// Ingests a kind 10002 event into the cache.
    /// - Returns: The effective list, or nil if the event is not a relay list metadata event.
    @discardableResult
    func ingest(_ event: Event) -> RelayListMetadata? {
        guard let list = event.relayListMetadata else {
            return nil
        }
        return store(list, createdAt: event.createdAt, for: event.publicKey)
    }

    /// Returns the cached relay list for a public key, if any.
    func cachedList(for publicKey: PublicKey) -> RelayListMetadata? {
        cache.value(for: publicKey)
    }

    /// Resolves the WRITE relays for a public key (where the user publishes) — use these to READ their events.
    func writeRelayURLs(for publicKey: PublicKey) -> Set<RelayURL> {
        Set(cache.value(for: publicKey)?.writeRelays ?? [])
    }

    /// Resolves the READ relays for a public key (their inbox) — use these to SEND them events they should see.
    func readRelayURLs(for publicKey: PublicKey) -> Set<RelayURL> {
        Set(cache.value(for: publicKey)?.readRelays ?? [])
    }

    /// Ensures the given relay URLs are present (and, for `.addAndConnect`, connected) in the pool,
    /// honoring the configured policy and per-resolve cap.
    /// - Returns: The subset of URLs available for routing.
    func ensureConnected(_ urls: Set<RelayURL>) async -> Set<RelayURL> {
        await connector.ensureConnected(urls)
    }
}
