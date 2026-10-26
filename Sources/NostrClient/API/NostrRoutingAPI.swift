import Foundation
import NostrCore

/// Where a user's events live and where their messages should be delivered: NIP-65 relay list
/// metadata with outbox/gossip routing, and NIP-17 DM relay lists.
/// Reached as ``NostrClient/routing``.
///
/// Both lists are cached per public key, newest wins, and both grow the pool per the client's
/// ``GossipRelayPolicy`` when a route resolves to a relay that is not connected yet.
///
/// Implements the ``NostrRelayRouting`` primitives over the client's relay-list caches and pool;
/// ``NostrRelayRouting/publishRelayList(read:write:strategy:)``,
/// ``NostrRelayRouting/publishDirectMessageRelayList(relays:strategy:)``, and the short forms come
/// from the protocol's extension.
public struct NostrRoutingAPI: NostrRelayRouting {
    let client: NostrClient

    // MARK: - Relay list metadata (NIP-65)

    /// Fetches a user's NIP-65 relay list (kind 10002), caching it (newer wins).
    public func fetchRelayList(for publicKey: PublicKey, timeout: Duration?) async throws -> RelayListMetadata? {
        let events = try await client.fetch(
            filters: [.relayListMetadata(publicKey: publicKey)], fromURLs: nil, timeout: timeout
        )
        // Replaceable event: the newest list this public key actually signed. Taking the newest of
        // whatever arrived let any relay install a list for someone else by dating it far ahead.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: .relayListMetadata, author: publicKey),
            let list = newest.relayListMetadata
        else {
            return nil
        }
        await client.relayListStore.store(list, createdAt: newest.createdAt, for: publicKey)
        return list
    }

    /// Returns the cached relay list for a public key without performing a network fetch.
    public func cachedRelayList(for publicKey: PublicKey) async -> RelayListMetadata? {
        await client.relayListStore.cachedList(for: publicKey)
    }

    /// Signs and publishes the current user's relay list metadata (kind 10002, NIP-65) to the whole
    /// pool, and caches it.
    @discardableResult
    public func publishRelayList(
        _ relayList: RelayListMetadata,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let event = try await client.sign(.relayListMetadata(relayList))
        let result = try await client.pool.publish(event, strategy: strategy)
        await client.relayListStore.store(relayList, createdAt: event.createdAt, for: event.publicKey)
        return PublishedEvent(event: event, result: result)
    }

    /// Subscribes to authors on their own WRITE relays (the NIP-65 outbox model), falling back to
    /// the whole pool when any author has no known relay list.
    public func subscribeOutbox(
        authors: [PublicKey],
        kinds: [Event.Kind],
        limit: Int?
    ) async throws -> SubscriptionSequence {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await client.subscribe(filters: [filter], toURLs: routeSet)
    }

    /// Publishes a signed event to the author's WRITE relays and its mentions' READ relays (the
    /// NIP-65 gossip model), falling back to the whole pool when nothing resolves.
    @discardableResult
    public func publishGossip(_ event: Event, strategy: PublishStrategy?) async throws -> PublishResult {
        var targets: Set<RelayURL> = []

        targets.formUnion(await writeRelays(for: event.publicKey))

        let referencedPublicKeys = Set(event.referencedPublicKeys)
        for publicKey in referencedPublicKeys {
            if await cachedRelayList(for: publicKey) == nil {
                _ = try? await fetchRelayList(for: publicKey)
            }
            targets.formUnion(await client.relayListStore.readRelayURLs(for: publicKey))
        }

        let available = await client.relayListStore.ensureConnected(targets)
        return try await client.pool.publish(
            event, to: available.isEmpty ? nil : available, strategy: strategy
        )
    }

    // MARK: - Direct message relay list (NIP-17, kind 10050)

    /// Fetches a user's NIP-17 DM relay list (kind 10050), caching it (newer wins).
    public func fetchDirectMessageRelayList(
        for publicKey: PublicKey,
        timeout: Duration?
    ) async throws -> DirectMessageRelayList? {
        let events = try await client.fetch(
            filters: [.directMessageRelayList(publicKey: publicKey)], fromURLs: nil, timeout: timeout
        )
        // Replaceable event: the newest list this public key actually signed. This one decides where
        // their private messages are delivered, so an unverified copy would let a relay redirect
        // them — the recipient never receives the message, and the sender's traffic goes to
        // whoever forged the list.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: .directMessageRelayList, author: publicKey),
            let list = newest.directMessageRelayList
        else {
            return nil
        }
        await client.dmRelayListStore.store(list, createdAt: newest.createdAt, for: publicKey)
        return list
    }

    /// Returns the cached DM relay list for a public key without performing a network fetch.
    public func cachedDirectMessageRelayList(for publicKey: PublicKey) async -> DirectMessageRelayList? {
        await client.dmRelayListStore.cachedList(for: publicKey)
    }

    /// Signs and publishes the current user's DM relay list (kind 10050, NIP-17) to the whole pool,
    /// and caches it.
    @discardableResult
    public func publishDirectMessageRelayList(
        _ relayList: DirectMessageRelayList,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let event = try await client.sign(.directMessageRelayList(relayList))
        let result = try await client.pool.publish(event, strategy: strategy)
        await client.dmRelayListStore.store(relayList, createdAt: event.createdAt, for: event.publicKey)
        return PublishedEvent(event: event, result: result)
    }

    /// Ensures the current user's own NIP-17 DM inbox relays (kind 10050) are in the pool and
    /// connected, fetching the list first when it is not cached.
    /// - Throws: ``NostrClient/Error/signerNotSet`` if no signer is configured.
    @discardableResult
    public func connectDirectMessageInboxRelays() async throws(NostrClient.Error) -> Set<RelayURL> {
        await connectedInboxRelays(for: try await client.requiredPublicKey())
    }

    // MARK: - Internal

    /// Resolves and connects a public key's kind-10050 DM inbox relays, fetching the list first if it
    /// is not cached and at least one relay is connected to query.
    ///
    /// Shared by the send path (routing a recipient's gift wrap) and the receive path
    /// (``connectDirectMessageInboxRelays()``).
    /// - Returns: The connected inbox relay URLs (empty if none are known or reachable).
    func connectedInboxRelays(for publicKey: PublicKey) async -> Set<RelayURL> {
        // Fetch only once per public key: skip it when the list is already resolved — cached, or a
        // prior lookup confirmed there is none — so repeated sends don't refetch. Discovery also
        // needs at least one connected relay to query, which avoids a blocking fetch against a
        // pool that cannot answer.
        if await client.dmRelayListStore.isResolved(for: publicKey) == false,
            await client.pool.connectedRelayCount() > 0
        {
            do {
                if try await fetchDirectMessageRelayList(for: publicKey) == nil {
                    await client.dmRelayListStore.markNoList(for: publicKey)
                }
            } catch {
                // Transient fetch failure: leave the public key unresolved so a later send can retry.
            }
        }
        let inboxURLs = await client.dmRelayListStore.inboxRelayURLs(for: publicKey)
        return await client.dmRelayListStore.ensureConnected(inboxURLs)
    }

    // MARK: - Private

    /// Resolves the WRITE relays of the given authors for outbox routing.
    /// - Returns: The connected target set, or `nil` to fall back to the full pool
    ///   when an author is unresolved or nothing could be connected.
    private func resolveOutboxRelays(authors: [PublicKey]) async -> Set<RelayURL>? {
        var targets: Set<RelayURL> = []
        var hasUnresolved = false

        for author in authors {
            let writeURLs = await writeRelays(for: author)
            if writeURLs.isEmpty {
                hasUnresolved = true
            } else {
                targets.formUnion(writeURLs)
            }
        }

        let available = await client.relayListStore.ensureConnected(targets)
        return (hasUnresolved || available.isEmpty) ? nil : available
    }

    /// A public key's WRITE relays, discovering its relay list first when nothing is cached.
    private func writeRelays(for publicKey: PublicKey) async -> Set<RelayURL> {
        if await cachedRelayList(for: publicKey) == nil {
            _ = try? await fetchRelayList(for: publicKey)
        }
        return await client.relayListStore.writeRelayURLs(for: publicKey)
    }
}
