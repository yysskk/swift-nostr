import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrRelayRouting {
    /// Fetches a user's NIP-65 relay list (kind 10002) from the whole pool, caching it (newer wins),
    /// waiting up to ``RelayPoolConfig/queryTimeout``. See
    /// ``NostrRelayRouting/fetchRelayList(for:timeout:)``.
    /// - Parameter publicKey: The user whose relay list to fetch.
    /// - Returns: The relay list, or nil if none was found.
    public func fetchRelayList(for publicKey: PublicKey) async throws -> RelayListMetadata? {
        try await fetchRelayList(for: publicKey, timeout: nil)
    }

    /// Signs and publishes the current user's NIP-65 relay list (kind 10002) to the whole pool,
    /// waiting for the pool config's ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrRelayRouting/publishRelayList(_:strategy:)``.
    /// - Parameter relayList: The relay list to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(_ relayList: RelayListMetadata) async throws -> PublishedEvent {
        try await publishRelayList(relayList, strategy: nil)
    }

    /// Subscribes to authors on their own WRITE relays (the NIP-65 outbox model), with no limit on
    /// the stored events each relay sends. See
    /// ``NostrRelayRouting/subscribeOutbox(authors:kinds:limit:)-(_,_,Int?)``.
    /// - Parameters:
    ///   - authors: The authors to follow.
    ///   - kinds: The event kinds to receive (default: text notes).
    /// - Returns: The subscription.
    public func subscribeOutbox(
        authors: [PublicKey],
        kinds: [Event.Kind] = [.textNote]
    ) async throws -> SubscriptionSequence {
        try await subscribeOutbox(authors: authors, kinds: kinds, limit: nil)
    }

    /// Subscribes to authors on their own WRITE relays (the NIP-65 outbox model), with each relay
    /// sending up to `limit` stored events before live ones. See
    /// ``NostrRelayRouting/subscribeOutbox(authors:kinds:limit:)-(_,_,Int?)``.
    /// - Parameters:
    ///   - authors: The authors to follow.
    ///   - kinds: The event kinds to receive (default: text notes).
    ///   - limit: How many stored events each relay sends before live ones.
    /// - Returns: The subscription.
    public func subscribeOutbox(
        authors: [PublicKey],
        kinds: [Event.Kind] = [.textNote],
        limit: Int
    ) async throws -> SubscriptionSequence {
        try await subscribeOutbox(authors: authors, kinds: kinds, limit: Optional(limit))
    }

    /// Publishes a signed event using the NIP-65 gossip model, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrRelayRouting/publishGossip(_:strategy:)``.
    /// - Parameter event: The already-signed event to route.
    /// - Returns: The per-relay outcome of the publish.
    @discardableResult
    public func publishGossip(_ event: Event) async throws -> PublishResult {
        try await publishGossip(event, strategy: nil)
    }

    /// Fetches a user's NIP-17 DM relay list (kind 10050) from the whole pool, caching it (newer
    /// wins), waiting up to ``RelayPoolConfig/queryTimeout``. See
    /// ``NostrRelayRouting/fetchDirectMessageRelayList(for:timeout:)``.
    /// - Parameter publicKey: The user whose DM relay list to fetch.
    /// - Returns: The DM relay list, or nil if none was found.
    public func fetchDirectMessageRelayList(for publicKey: PublicKey) async throws -> DirectMessageRelayList? {
        try await fetchDirectMessageRelayList(for: publicKey, timeout: nil)
    }

    /// Signs and publishes the current user's NIP-17 DM relay list (kind 10050) to the whole pool,
    /// waiting for the pool config's ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrRelayRouting/publishDirectMessageRelayList(_:strategy:)``.
    /// - Parameter relayList: The DM relay list to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDirectMessageRelayList(_ relayList: DirectMessageRelayList) async throws -> PublishedEvent {
        try await publishDirectMessageRelayList(relayList, strategy: nil)
    }
}

// MARK: - Conveniences

extension NostrRelayRouting {
    /// Signs and publishes the current user's NIP-65 relay list (kind 10002) built from read and
    /// write relay URLs — a URL in both is read+write. See
    /// ``NostrRelayRouting/publishRelayList(_:strategy:)``.
    /// - Parameters:
    ///   - read: The relays the user reads from (their inbox).
    ///   - write: The relays the user writes to (their outbox).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishRelayList(
        read: [RelayURL] = [],
        write: [RelayURL] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publishRelayList(RelayListMetadata(read: read, write: write), strategy: strategy)
    }

    /// Signs and publishes the current user's NIP-17 DM relay list (kind 10050) built from relay
    /// URLs. See ``NostrRelayRouting/publishDirectMessageRelayList(_:strategy:)``.
    /// - Parameters:
    ///   - relays: The relays the user receives direct messages on; NIP-17 recommends 1–3.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishDirectMessageRelayList(
        relays: [RelayURL],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publishDirectMessageRelayList(DirectMessageRelayList(relays: relays), strategy: strategy)
    }
}
