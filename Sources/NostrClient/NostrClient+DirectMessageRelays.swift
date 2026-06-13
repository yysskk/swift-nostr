import Foundation

// MARK: - Direct Message Relay List (NIP-17, kind 10050)
extension NostrClient {
    /// Fetches a user's NIP-17 DM relay list (kind 10050), caching it (newer wins).
    ///
    /// Look this up to learn where to deliver a recipient's gift-wrapped direct messages.
    /// - Returns: The DM relay list, or nil if none was found.
    public func fetchDirectMessageRelayList(
        for pubkey: String,
        timeout: TimeInterval = 10
    ) async throws -> DirectMessageRelayList? {
        let events = try await fetch(filters: [.directMessageRelayList(pubkey: pubkey)], timeout: timeout)
        // Replaceable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }),
            let list = newest.directMessageRelayList
        else {
            return nil
        }
        await dmRelayListStore.store(list, createdAt: newest.createdAt, for: pubkey)
        return list
    }

    /// Returns the cached DM relay list for a pubkey without performing a network fetch.
    public func cachedDirectMessageRelayList(for pubkey: String) async -> DirectMessageRelayList? {
        await dmRelayListStore.cachedList(for: pubkey)
    }

    /// Signs and publishes the current user's DM relay list (kind 10050, NIP-17).
    ///
    /// The list advertises where the user receives private direct messages. It is broadcast to all
    /// relays in the pool for discoverability. NIP-17 recommends keeping the list short (1–3 relays).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDirectMessageRelayList(
        _ relayList: DirectMessageRelayList,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let (event, authorPubkey) = try withSigner { signer in
            (try signer.signDirectMessageRelayList(relayList), signer.publicKey)
        }
        let result = try await relayPool.publish(event, strategy: strategy)
        await dmRelayListStore.store(relayList, createdAt: event.createdAt, for: authorPubkey)
        return PublishedEvent(event: event, result: result)
    }

    /// Signs and publishes the current user's DM relay list from relay URLs (NIP-17, kind 10050).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDirectMessageRelayList(
        relays: [String],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publishDirectMessageRelayList(DirectMessageRelayList(relays: relays), strategy: strategy)
    }
}
