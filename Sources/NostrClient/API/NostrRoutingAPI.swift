import Foundation
import NostrCore

/// Where a user's events live and where their messages should be delivered: NIP-65 relay list
/// metadata with outbox/gossip routing, and NIP-17 DM relay lists.
/// Reached as ``NostrClient/routing``.
///
/// Both lists are cached per pubkey, newest wins, and both grow the pool per the client's
/// ``GossipRelayPolicy`` when a route resolves to a relay that is not connected yet.
public struct NostrRoutingAPI: NostrRelayRouting {
    let client: NostrClient

    // MARK: - Relay list metadata (NIP-65)

    /// Fetches a user's NIP-65 relay list (kind 10002), caching it (newer wins).
    /// - Returns: The relay list, or nil if none was found.
    public func fetchRelayList(for pubkey: String, timeout: TimeInterval = 10) async throws -> RelayListMetadata? {
        let events = try await client.fetch(
            filters: [.relayListMetadata(pubkey: pubkey)], toURLs: nil, timeout: timeout
        )
        // Replaceable event: the newest list this pubkey actually signed. Taking the newest of
        // whatever arrived let any relay install a list for someone else by dating it far ahead.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: .relayListMetadata, author: pubkey),
            let list = newest.relayListMetadata
        else {
            return nil
        }
        await client.relayListStore.store(list, createdAt: newest.createdAt, for: pubkey)
        return list
    }

    /// Returns the cached relay list for a pubkey without performing a network fetch.
    public func cachedRelayList(for pubkey: String) async -> RelayListMetadata? {
        await client.relayListStore.cachedList(for: pubkey)
    }

    /// Signs and publishes the current user's relay list metadata (kind 10002, NIP-65).
    /// The list is broadcast to all relays in the pool for discoverability.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        _ relayList: RelayListMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try await client.signEvent { .relayListMetadata(pubkey: $0, relayList) }
        let result = try await client.pool.publish(event, strategy: strategy)
        await client.relayListStore.store(relayList, createdAt: event.createdAt, for: event.pubkey)
        return PublishedEvent(event: event, result: result)
    }

    /// Signs and publishes the current user's relay list metadata from read/write relay URLs (NIP-65).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        read: [String] = [],
        write: [String] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publishRelayList(RelayListMetadata(read: read, write: write), strategy: strategy)
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    ///
    /// For each author, resolves their WRITE relays (fetching the relay list if not cached),
    /// connects them per the gossip policy, and issues a single subscription scoped to those relays.
    /// If any author has no known relay list, the subscription falls back to the full relay pool so
    /// no author is silently dropped; the fallback throws ``NostrError/noRelaysInPool`` when the
    /// pool is also empty.
    public func subscribeOutbox(
        authors: [String],
        kinds: [Event.Kind] = [.textNote],
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await client.subscribe(filters: [filter], toURLs: routeSet)
    }

    /// Publishes a signed event using the NIP-65 gossip model.
    ///
    /// Routes the event to the author's own WRITE relays plus the READ (inbox) relays of every
    /// pubkey referenced in the event's "p" tags, so mentions and replies reach their recipients.
    /// Falls back to the full relay pool if nothing resolves; the fallback throws
    /// ``NostrError/noRelaysInPool`` when the pool is also empty.
    /// - Parameters:
    ///   - event: The already-signed event to route.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publishGossip(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        var targets: Set<URL> = []

        targets.formUnion(await writeRelays(for: event.pubkey))

        let referencedPubkeys = Set(event.referencedPubkeys)
        for pubkey in referencedPubkeys {
            if await cachedRelayList(for: pubkey) == nil {
                _ = try? await fetchRelayList(for: pubkey)
            }
            targets.formUnion(await client.relayListStore.readRelayURLs(for: pubkey))
        }

        let available = await client.relayListStore.ensureConnected(targets)
        return try await client.pool.publish(
            event, toURLs: available.isEmpty ? nil : available, strategy: strategy
        )
    }

    // MARK: - Direct message relay list (NIP-17, kind 10050)

    /// Fetches a user's NIP-17 DM relay list (kind 10050), caching it (newer wins).
    ///
    /// Look this up to learn where to deliver a recipient's gift-wrapped direct messages.
    /// - Returns: The DM relay list, or nil if none was found.
    public func fetchDirectMessageRelayList(
        for pubkey: String,
        timeout: TimeInterval = 10
    ) async throws -> DirectMessageRelayList? {
        let events = try await client.fetch(
            filters: [.directMessageRelayList(pubkey: pubkey)], toURLs: nil, timeout: timeout
        )
        // Replaceable event: the newest list this pubkey actually signed. This one decides where
        // their private messages are delivered, so an unverified copy would let a relay redirect
        // them — the recipient never receives the message, and the sender's traffic goes to
        // whoever forged the list.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: .directMessageRelayList, author: pubkey),
            let list = newest.directMessageRelayList
        else {
            return nil
        }
        await client.dmRelayListStore.store(list, createdAt: newest.createdAt, for: pubkey)
        return list
    }

    /// Returns the cached DM relay list for a pubkey without performing a network fetch.
    public func cachedDirectMessageRelayList(for pubkey: String) async -> DirectMessageRelayList? {
        await client.dmRelayListStore.cachedList(for: pubkey)
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
        let event = try await client.signEvent { .directMessageRelayList(pubkey: $0, relayList) }
        let result = try await client.pool.publish(event, strategy: strategy)
        await client.dmRelayListStore.store(relayList, createdAt: event.createdAt, for: event.pubkey)
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
    /// Call this before subscribing with ``NostrMessagesAPI/subscribe(limit:)`` or
    /// ``NostrMessagesAPI/giftWraps(limit:)`` so the subscription covers the relays you advertised.
    /// - Returns: The connected inbox relay URLs (empty if you have advertised no DM relay list).
    /// - Throws: ``NostrError/signerNotSet`` if no signer is configured.
    @discardableResult
    public func connectDirectMessageInboxRelays() async throws -> Set<URL> {
        await connectedInboxRelays(for: try await client.requiredPublicKey())
    }

    // MARK: - Internal

    /// Resolves and connects a pubkey's kind-10050 DM inbox relays, fetching the list first if it
    /// is not cached and at least one relay is connected to query.
    ///
    /// Shared by the send path (routing a recipient's gift wrap) and the receive path
    /// (``connectDirectMessageInboxRelays()``).
    /// - Returns: The connected inbox relay URLs (empty if none are known or reachable).
    func connectedInboxRelays(for pubkey: String) async -> Set<URL> {
        // Fetch only once per pubkey: skip it when the list is already resolved — cached, or a
        // prior lookup confirmed there is none — so repeated sends don't refetch. Discovery also
        // needs at least one connected relay to query, which avoids a blocking fetch against a
        // pool that cannot answer.
        if await client.dmRelayListStore.isResolved(for: pubkey) == false,
            await client.pool.connectedCount() > 0
        {
            do {
                if try await fetchDirectMessageRelayList(for: pubkey) == nil {
                    await client.dmRelayListStore.markNoList(for: pubkey)
                }
            } catch {
                // Transient fetch failure: leave the pubkey unresolved so a later send can retry.
            }
        }
        let inboxURLs = await client.dmRelayListStore.inboxRelayURLs(for: pubkey)
        return await client.dmRelayListStore.ensureConnected(inboxURLs)
    }

    // MARK: - Private

    /// Resolves the WRITE relays of the given authors for outbox routing.
    /// - Returns: The connected target set, or `nil` to fall back to the full pool
    ///   when an author is unresolved or nothing could be connected.
    private func resolveOutboxRelays(authors: [String]) async -> Set<URL>? {
        var targets: Set<URL> = []
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

    /// A pubkey's WRITE relays, discovering its relay list first when nothing is cached.
    private func writeRelays(for pubkey: String) async -> Set<URL> {
        if await cachedRelayList(for: pubkey) == nil {
            _ = try? await fetchRelayList(for: pubkey)
        }
        return await client.relayListStore.writeRelayURLs(for: pubkey)
    }
}
