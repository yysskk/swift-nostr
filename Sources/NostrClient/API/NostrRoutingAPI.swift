import Foundation
import NostrCore

/// Where a user's events live and where their messages should be delivered: NIP-65 relay list
/// metadata and NIP-17 DM relay lists. Reached as ``NostrClient/routing``.
///
/// Both lists are cached per public key, newest wins, and both grow the pool per the client's
/// ``GossipRelayPolicy`` when a route resolves to a relay that is not connected yet. The NIP-65
/// lists drive ``RelayRoute/outbox``, which every publish, fetch, count, and subscription accepts.
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

    /// The relays a publish of `event` along `route` targets, or nil for the whole pool.
    ///
    /// For ``RelayRoute/outbox``: the author's WRITE relays plus the READ relays of every public key
    /// in its "p" tags, connected per the ``GossipRelayPolicy``, or nil when nothing resolves. When
    /// none of the author's WRITE relays is available, the whole pool is targeted alongside the
    /// recipients' READ relays, so the event still reaches relays the author's readers can find.
    func relayURLs(publishing event: Event, along route: RelayRoute) async -> Set<RelayURL>? {
        switch route {
        case .pool: return nil
        case .relays(let relayURLs): return relayURLs
        case .outbox: break
        }
        let recipients = Set(event.referencedPublicKeys)
        await discoverRelayLists(for: recipients.union([event.publicKey]))
        let authorURLs = await client.relayListStore.writeRelayURLs(for: event.publicKey)
        var targets = authorURLs
        for publicKey in recipients {
            targets.formUnion(await client.relayListStore.readRelayURLs(for: publicKey))
        }
        let available = await client.relayListStore.ensureConnected(targets)
        guard !available.isEmpty else { return nil }
        guard available.isDisjoint(with: authorURLs) else { return available }
        return available.union(await client.pool.connections.map(\.url))
    }

    /// The relays a read of `filters` along `route` targets, or nil for the whole pool.
    ///
    /// For ``RelayRoute/outbox``: the WRITE relays of the filters' authors, connected per the
    /// ``GossipRelayPolicy``, or nil when a filter names no authors, an author has no known relay
    /// list, or nothing could be connected.
    func relayURLs(reading filters: [Filter], along route: RelayRoute) async -> Set<RelayURL>? {
        switch route {
        case .pool: return nil
        case .relays(let relayURLs): return relayURLs
        case .outbox: break
        }
        await discoverRelayLists(for: Set(filters.flatMap { $0.authors ?? [] }))
        // A filter without authors can match anyone's events, and an author with no known relay list
        // would be silently dropped, so either falls back to the whole pool — after connecting the
        // relays that did resolve, which the pool then covers too.
        var fallsBackToPool = false
        var targets: Set<RelayURL> = []
        for filter in filters {
            guard let authors = filter.authors, !authors.isEmpty else {
                fallsBackToPool = true
                continue
            }
            for author in authors {
                let writeURLs = await client.relayListStore.writeRelayURLs(for: author)
                if writeURLs.isEmpty {
                    fallsBackToPool = true
                } else {
                    targets.formUnion(writeURLs)
                }
            }
        }
        let available = await client.relayListStore.ensureConnected(targets)
        return (fallsBackToPool || available.isEmpty) ? nil : available
    }

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

    /// Discovers the NIP-65 relay lists of the public keys not yet resolved in one kind-10002 query,
    /// when at least one relay is connected to ask.
    ///
    /// Each list is validated as in ``fetchRelayList(for:timeout:)`` (newest list the key signed),
    /// and a key the completed query returned no list for is marked as having none, so later routes
    /// skip it; as in ``connectedInboxRelays(for:)``, a query that times out counts as completed. A
    /// failed query leaves every key unresolved for a later retry.
    private func discoverRelayLists(for publicKeys: Set<PublicKey>) async {
        var missing: [PublicKey] = []
        for publicKey in publicKeys where await client.relayListStore.isResolved(for: publicKey) == false {
            missing.append(publicKey)
        }
        guard !missing.isEmpty, await client.pool.connectedRelayCount() > 0 else { return }
        guard
            let events = try? await client.fetch(
                filters: [.relayListMetadata(publicKeys: missing)], fromURLs: nil, timeout: nil)
        else {
            return
        }
        for publicKey in missing {
            if let newest = VerifiedEventSelection.newest(in: events, kind: .relayListMetadata, author: publicKey),
                let list = newest.relayListMetadata
            {
                await client.relayListStore.store(list, createdAt: newest.createdAt, for: publicKey)
            } else {
                await client.relayListStore.markNoList(for: publicKey)
            }
        }
    }
}
