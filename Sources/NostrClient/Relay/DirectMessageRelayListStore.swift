import Foundation

/// Caches per-pubkey NIP-17 DM relay lists (kind 10050) and resolves the inbox relay set where a
/// user's gift-wrapped direct messages should be delivered.
///
/// Owned by `NostrClient`; routes through the same shared `RelayPool` as the NIP-65
/// ``RelayListStore`` via a ``RelayConnector``.
actor DirectMessageRelayListStore {
    private var cache = ReplaceableCache<DirectMessageRelayList>()
    private let connector: RelayConnector

    init(pool: RelayPool, policy: GossipRelayPolicy = .addAndConnect, maxRelaysPerResolve: Int = 8) {
        self.connector = RelayConnector(pool: pool, policy: policy, maxRelaysPerResolve: maxRelaysPerResolve)
    }

    /// Stores a DM relay list if it is newer than the cached one (replaceable-event semantics: newer wins).
    /// An equal `createdAt` keeps the existing entry.
    /// - Returns: The effective (possibly pre-existing) list.
    @discardableResult
    func store(_ list: DirectMessageRelayList, createdAt: Int64, for pubkey: String) -> DirectMessageRelayList {
        cache.store(list, createdAt: createdAt, for: pubkey)
    }

    /// Ingests a kind 10050 event into the cache.
    /// - Returns: The effective list, or nil if the event is not a DM relay list event.
    @discardableResult
    func ingest(_ event: Event) -> DirectMessageRelayList? {
        guard let list = event.directMessageRelayList else {
            return nil
        }
        return store(list, createdAt: event.createdAt, for: event.pubkey)
    }

    /// Returns the cached DM relay list for a pubkey, if any.
    func cachedList(for pubkey: String) -> DirectMessageRelayList? {
        cache.value(for: pubkey)
    }

    /// Resolves the inbox relays for a pubkey — where their gift-wrapped DMs should be delivered.
    func inboxRelayURLs(for pubkey: String) -> Set<URL> {
        RelayURL.urlSet(cache.value(for: pubkey)?.relays ?? [])
    }

    /// Ensures the given relay URLs are present (and, for `.addAndConnect`, connected) in the pool,
    /// honoring the configured policy and per-resolve cap.
    /// - Returns: The subset of URLs available for routing.
    func ensureConnected(_ urls: Set<URL>) async -> Set<URL> {
        await connector.ensureConnected(urls)
    }
}
