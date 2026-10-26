import Foundation
import NostrCore

/// Caches per-public-key NIP-17 DM relay lists (kind 10050) and resolves the inbox relay set where a
/// user's gift-wrapped direct messages should be delivered.
///
/// Owned by `NostrClient`; routes through the same shared `RelayPool` as the NIP-65
/// ``RelayListStore`` via a ``RelayConnector``.
actor DirectMessageRelayListStore {
    private var cache = ReplaceableCache<DirectMessageRelayList>()
    /// Public keys a lookup confirmed have no kind 10050 event. This negative cache lets
    /// the send path skip a repeat network fetch for every message to such a peer.
    private var resolvedWithoutList: Set<PublicKey> = []
    private let connector: RelayConnector

    init(pool: RelayPool, policy: GossipRelayPolicy = .addAndConnect, maxRelaysPerResolve: Int = 8) {
        self.connector = RelayConnector(pool: pool, policy: policy, maxRelaysPerResolve: maxRelaysPerResolve)
    }

    /// Stores a DM relay list if it is newer than the cached one (replaceable-event semantics: newer wins).
    /// An equal `createdAt` keeps the existing entry.
    /// - Returns: The effective (possibly pre-existing) list.
    @discardableResult
    func store(_ list: DirectMessageRelayList, createdAt: Timestamp, for publicKey: PublicKey) -> DirectMessageRelayList
    {
        // A real list supersedes any earlier "no list" result for this public key.
        resolvedWithoutList.remove(publicKey)
        return cache.store(list, createdAt: createdAt, for: publicKey)
    }

    /// Records that a network lookup found no DM relay list for `publicKey`, so repeated
    /// resolutions can skip the fetch. A later kind 10050 (via ``store(_:createdAt:for:)``
    /// or ``ingest(_:)``) clears the mark.
    func markNoList(for publicKey: PublicKey) {
        resolvedWithoutList.insert(publicKey)
    }

    /// Whether this public key's DM relay list has already been resolved — either a list is
    /// cached, or a lookup confirmed there is none — so another network fetch can be skipped.
    func isResolved(for publicKey: PublicKey) -> Bool {
        cache.value(for: publicKey) != nil || resolvedWithoutList.contains(publicKey)
    }

    /// Ingests a kind 10050 event into the cache.
    /// - Returns: The effective list, or nil if the event is not a DM relay list event.
    @discardableResult
    func ingest(_ event: Event) -> DirectMessageRelayList? {
        guard let list = event.directMessageRelayList else {
            return nil
        }
        return store(list, createdAt: event.createdAt, for: event.publicKey)
    }

    /// Returns the cached DM relay list for a public key, if any.
    func cachedList(for publicKey: PublicKey) -> DirectMessageRelayList? {
        cache.value(for: publicKey)
    }

    /// Resolves the inbox relays for a public key — where their gift-wrapped DMs should be delivered.
    func inboxRelayURLs(for publicKey: PublicKey) -> Set<RelayURL> {
        Set(cache.value(for: publicKey)?.relays ?? [])
    }

    /// Ensures the given relay URLs are present (and, for `.addAndConnect`, connected) in the pool,
    /// honoring the configured policy and per-resolve cap.
    /// - Returns: The subset of URLs available for routing.
    func ensureConnected(_ urls: Set<RelayURL>) async -> Set<RelayURL> {
        await connector.ensureConnected(urls)
    }
}
