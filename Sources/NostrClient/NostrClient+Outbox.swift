import Foundation
import NostrCore

// MARK: - Relay List Metadata & Outbox/Gossip (NIP-65)
extension NostrClient {
    /// Fetches a user's NIP-65 relay list (kind 10002), caching it (newer wins).
    /// - Returns: The relay list, or nil if none was found.
    public func fetchRelayList(for pubkey: String, timeout: TimeInterval = 10) async throws -> RelayListMetadata? {
        let events = try await fetch(filters: [.relayListMetadata(pubkey: pubkey)], timeout: timeout)
        // Replaceable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }),
            let list = newest.relayListMetadata
        else {
            return nil
        }
        await relayListStore.store(list, createdAt: newest.createdAt, for: pubkey)
        return list
    }

    /// Returns the cached relay list for a pubkey without performing a network fetch.
    public func cachedRelayList(for pubkey: String) async -> RelayListMetadata? {
        await relayListStore.cachedList(for: pubkey)
    }

    /// Signs and publishes the current user's relay list metadata (kind 10002, NIP-65).
    /// The list is broadcast to all relays in the pool for discoverability.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        _ relayList: RelayListMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let (event, authorPubkey) = try withSigner { signer in
            (try signer.signRelayListMetadata(relayList), signer.publicKey)
        }
        let result = try await relayPool.publish(event, strategy: strategy)
        await relayListStore.store(relayList, createdAt: event.createdAt, for: authorPubkey)
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
        let (event, authorPubkey) = try withSigner { signer in
            (try signer.signRelayListMetadata(read: read, write: write), signer.publicKey)
        }
        let result = try await relayPool.publish(event, strategy: strategy)
        if let list = event.relayListMetadata {
            await relayListStore.store(list, createdAt: event.createdAt, for: authorPubkey)
        }
        return PublishedEvent(event: event, result: result)
    }

    /// Subscribes to events from multiple authors using the NIP-65 outbox model.
    ///
    /// For each author, resolves their WRITE relays (fetching the relay list if not cached),
    /// connects them per the gossip policy, and issues a single subscription scoped to those relays.
    /// If any author has no known relay list, the subscription falls back to the full relay pool so
    /// no author is silently dropped.
    public func subscribeOutbox(
        authors: [String],
        kinds: [Event.Kind] = [.textNote],
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        let routeSet = await resolveOutboxRelays(authors: authors)
        let filter = Filter(authors: authors, kinds: kinds, limit: limit)
        return try await subscribe(filters: [filter], to: routeSet)
    }

    /// Resolves the WRITE relays of the given authors for outbox routing.
    /// - Returns: The connected target set, or `nil` to fall back to the full pool
    ///   when an author is unresolved or nothing could be connected.
    private func resolveOutboxRelays(authors: [String]) async -> Set<URL>? {
        var targets: Set<URL> = []
        var hasUnresolved = false

        for author in authors {
            if await relayListStore.cachedList(for: author) == nil {
                _ = try? await fetchRelayList(for: author)
            }
            let writeURLs = await relayListStore.writeRelayURLs(for: author)
            if writeURLs.isEmpty {
                hasUnresolved = true
            } else {
                targets.formUnion(writeURLs)
            }
        }

        let available = await relayListStore.ensureConnected(targets)
        return (hasUnresolved || available.isEmpty) ? nil : available
    }

    /// Publishes a signed event using the NIP-65 gossip model.
    ///
    /// Routes the event to the author's own WRITE relays plus the READ (inbox) relays of every
    /// pubkey referenced in the event's "p" tags, so mentions and replies reach their recipients.
    /// Falls back to the full relay pool if nothing resolves.
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publishGossip(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        var targets: Set<URL> = []

        if await relayListStore.cachedList(for: event.pubkey) == nil {
            _ = try? await fetchRelayList(for: event.pubkey)
        }
        targets.formUnion(await relayListStore.writeRelayURLs(for: event.pubkey))

        let referencedPubkeys = Set(event.referencedPubkeys)
        for pubkey in referencedPubkeys {
            if await relayListStore.cachedList(for: pubkey) == nil {
                _ = try? await fetchRelayList(for: pubkey)
            }
            targets.formUnion(await relayListStore.readRelayURLs(for: pubkey))
        }

        let available = await relayListStore.ensureConnected(targets)
        return try await relayPool.publish(event, to: available.isEmpty ? nil : available, strategy: strategy)
    }
}
