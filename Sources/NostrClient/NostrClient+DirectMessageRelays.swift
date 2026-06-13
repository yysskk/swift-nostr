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

    /// Ensures the current user's own NIP-17 DM inbox relays (kind 10050) are present and connected
    /// in the pool, so gift-wrapped messages addressed there are received. Fetches the user's DM
    /// relay list first if it is not already cached.
    ///
    /// Call this before subscribing with ``directMessages(limit:)`` or
    /// ``subscribeToDirectMessages(limit:)`` so the subscription covers the relays you advertised.
    /// - Returns: The connected inbox relay URLs (empty if you have advertised no DM relay list).
    /// - Throws: ``NostrError/signerNotSet`` if no signer is configured.
    @discardableResult
    public func connectDirectMessageInboxRelays() async throws -> Set<URL> {
        guard let publicKey = publicKey else {
            throw NostrError.signerNotSet
        }
        return await connectedDirectMessageInboxRelays(for: publicKey)
    }

    /// Resolves and connects a pubkey's kind-10050 DM inbox relays, fetching the list first if it
    /// is not cached and at least one relay is connected to query.
    ///
    /// Shared by the send path (routing a recipient's gift wrap) and the receive path
    /// (``connectDirectMessageInboxRelays()``).
    /// - Returns: The connected inbox relay URLs (empty if none are known or reachable).
    func connectedDirectMessageInboxRelays(for pubkey: String) async -> Set<URL> {
        // Fetch only once per pubkey: skip it when the list is already resolved — cached, or a
        // prior lookup confirmed there is none — so repeated sends don't refetch. Discovery also
        // needs at least one connected relay to query, which avoids a blocking fetch against a
        // pool that cannot answer.
        if await dmRelayListStore.isResolved(for: pubkey) == false, await relayPool.connectedCount() > 0 {
            do {
                if try await fetchDirectMessageRelayList(for: pubkey) == nil {
                    await dmRelayListStore.markNoList(for: pubkey)
                }
            } catch {
                // Transient fetch failure: leave the pubkey unresolved so a later send can retry.
            }
        }
        let inboxURLs = await dmRelayListStore.inboxRelayURLs(for: pubkey)
        return await dmRelayListStore.ensureConnected(inboxURLs)
    }
}
