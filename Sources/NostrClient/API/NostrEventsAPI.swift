import Foundation
import NostrCore

/// Authoring and publishing events, and fetching them one time.
/// Reached as ``NostrClient/events``.
///
/// Every `publish*` helper signs through the configured signer — local or remote NIP-46 — and
/// broadcasts to the whole pool. Use ``NostrRoutingAPI/publishGossip(_:strategy:)`` instead to
/// route by NIP-65, and ``NostrSubscriptionsAPI`` for live streams rather than one-time fetches.
public struct NostrEventsAPI: NostrEventPublishing, NostrEventFetching {
    let client: NostrClient

    // MARK: - Publishing

    /// Publishes a text note
    /// - Parameters:
    ///   - content: The note's text.
    ///   - tags: Tags to attach to the note.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishTextNote(
        content: String,
        tags: [Tag] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .textNote(pubkey: $0, content: content, tags: tags) }
    }

    /// Publishes a reply to an event
    /// - Parameters:
    ///   - event: The event being replied to; its thread root and author are carried over.
    ///   - content: The reply's text.
    ///   - relayURL: The relay where the replied-to event can be found, recorded in the
    ///     NIP-10 `e` tag.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReply(
        to event: Event,
        content: String,
        relayURL: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { publicKey in
            var tags: [Tag] = []

            // Carry over the thread root (NIP-10). The marker lives at a fixed position —
            // ["e", id, relay, marker] — so it is read there rather than searched for anywhere in
            // the tag: a relay hint or pubkey that happens to read "root" is not a marker.
            let parentEventTags = event.tags(named: "e")
            let markedRoot = parentEventTags.first {
                $0.values.count >= 3 && $0.values[2] == Tag.EventMarker.root.rawValue
            }

            // NIP-10's deprecated positional form carries no markers, and there the first "e" tag
            // is the root. Without this the parent looked rootless and the reply started a second
            // thread alongside the one it was answering.
            let positionalRoot =
                parentEventTags.allSatisfy { $0.values.count < 3 } ? parentEventTags.first : nil

            if let rootTag = markedRoot ?? positionalRoot {
                tags.append(rootTag)
                tags.append(.event(event.id, relayURL: relayURL, marker: .reply))
            } else {
                // This is a reply to a root event
                tags.append(.event(event.id, relayURL: relayURL, marker: .root))
            }

            // Add p tag for the author we're replying to
            tags.append(.pubkey(event.pubkey))

            return .textNote(pubkey: publicKey, content: content, tags: tags)
        }
    }

    /// Publishes user metadata
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishMetadata(
        _ metadata: UserMetadata,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { try .metadata(pubkey: $0, metadata) }
    }

    /// Publishes a reaction to an event
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReaction(
        to event: Event,
        content: String = "+",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .reaction(pubkey: $0, to: event, content: content) }
    }

    /// Publishes a repost
    /// - Parameters:
    ///   - event: The event being reposted.
    ///   - relayURL: The relay where the reposted event can be found, recorded in the `e` tag.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRepost(
        of event: Event,
        relayURL: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { try .repost(pubkey: $0, of: event, relayURL: relayURL) }
    }

    /// Publishes a deletion request
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDeletion(
        eventIds: [String],
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .deletion(pubkey: $0, eventIds: eventIds, reason: reason) }
    }

    /// Publishes a report of a pubkey (kind 1984, NIP-56).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReport(
        pubkey: String,
        type: ReportType,
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .report(pubkey: $0, target: pubkey, type: type, reason: reason) }
    }

    /// Publishes a report of an event and its author (kind 1984, NIP-56).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishReport(
        event: Event,
        type: ReportType,
        reason: String = "",
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .report(pubkey: $0, event: event, type: type, reason: reason) }
    }

    /// Publishes a raw signed event.
    /// - Parameters:
    ///   - event: The already-signed event to broadcast.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publish(_ event: Event, strategy: PublishStrategy? = nil) async throws -> PublishResult {
        try await client.pool.publish(event, strategy: strategy)
    }

    // MARK: - Long-form content (NIP-23)

    /// Signs and publishes a long-form article; the same identifier replaces the previous version.
    /// - Parameters:
    ///   - article: The article to publish; its `identifier` addresses the replaceable event.
    ///   - draft: Publishes as a kind 30024 draft instead of a kind 30023 article.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishLongFormContent(
        _ article: LongFormContent,
        draft: Bool = false,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await signAndPublish(strategy: strategy) { .longFormContent(pubkey: $0, article, draft: draft) }
    }

    /// Fetches an article by author and identifier, keeping the newest copy across relays.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(
        author: String,
        identifier: String,
        timeout: TimeInterval = 10
    ) async throws -> LongFormContent? {
        var filter = Filter(authors: [author], kinds: [.longFormContent])
        filter.addTagQuery("d", values: [identifier])
        let events = try await client.fetch(filters: [filter], toURLs: nil, timeout: timeout)
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return LongFormContent(event: newest)
    }

    /// Fetches the article addressed by an `naddr` coordinate.
    ///
    /// Any relay hints carried by the coordinate are used only when they are already in the pool;
    /// otherwise the whole pool is queried.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(naddr: NAddr, timeout: TimeInterval = 10) async throws -> LongFormContent? {
        var filter = Filter(authors: [naddr.author], kinds: [Event.Kind(rawValue: naddr.kind)])
        filter.addTagQuery("d", values: [naddr.identifier])

        // Use the coordinate's relay hints only where they are already connected in the pool.
        var hinted: Set<URL> = []
        for relay in naddr.relays {
            guard let url = URL(string: relay) else { continue }
            if await client.pool.relay(for: url) != nil {
                hinted.insert(url)
            }
        }

        let events = try await client.fetch(
            filters: [filter], toURLs: hinted.isEmpty ? nil : hinted, timeout: timeout
        )
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return LongFormContent(event: newest)
    }

    // MARK: - One-time fetches

    /// Fetches events matching the given filters (one-time)
    /// Waits for all subscribed relays to send EOSE, or until timeout (whichever comes first).
    ///
    /// Pass relay URL strings to scope the fetch to a subset of relays (e.g. `naddr` relay
    /// hints); the default `nil` fetches from all relays in the pool. Targets de-duplicate
    /// by their normalized routing key; an empty array always throws.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` for an invalid target string, and
    ///   ``NostrError/noRelaysInPool`` or ``NostrError/noMatchingRelays(_:)``
    ///   (via the underlying subscribe) when nothing can be targeted.
    public func fetch(
        filters: [Filter],
        to relayURLs: [String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> [Event] {
        try await client.fetch(
            filters: filters,
            toURLs: relayURLs.map(RelayURL.requireTargets),
            timeout: timeout
        )
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT).
    ///
    /// Queries the targeted relays and returns the maximum reported count — each relay's
    /// count is a lower bound on the events it holds, so the maximum is the best single estimate.
    /// `relayURLs` is nil (the default) to query the whole pool, or relay URL strings to
    /// target a subset; an empty array always throws. For per-relay results use
    /// ``RelayPool/count(filters:to:timeout:)`` on ``NostrRelaysAPI/pool``.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` for an invalid target string,
    ///   ``NostrError/noRelaysInPool`` when the pool is empty, or
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool.
    public func count(
        filters: [Filter],
        to relayURLs: [String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Int {
        let results = try await client.pool.count(
            filters: filters,
            toURLs: relayURLs.map(RelayURL.requireTargets),
            timeout: timeout
        )
        return results.values.map(\.value).max() ?? 0
    }

    /// Fetches a single event by ID
    public func fetchEvent(id: String, timeout: TimeInterval = 10) async throws -> Event? {
        let events = try await client.fetch(filters: [Filter(ids: [id])], toURLs: nil, timeout: timeout)
        return events.first
    }

    /// Fetches user metadata
    public func fetchMetadata(pubkey: String, timeout: TimeInterval = 10) async throws -> UserMetadata? {
        let events = try await client.fetch(
            filters: [.metadata(pubkeys: [pubkey])], toURLs: nil, timeout: timeout
        )

        guard let event = events.first else { return nil }

        return try? JSONDecoder().decode(UserMetadata.self, from: Data(event.content.utf8))
    }

    // MARK: - Private

    /// Builds an event under the signer's pubkey, signs it, and broadcasts it to the whole pool —
    /// the shape every convenience `publish*` helper above shares.
    private func signAndPublish(
        strategy: PublishStrategy?,
        _ build: @Sendable (_ publicKey: String) throws -> UnsignedEvent
    ) async throws -> PublishedEvent {
        let event = try await client.signEvent(build)
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }
}
