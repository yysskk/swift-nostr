import Foundation
import NostrCore

/// Authoring and publishing events, and fetching them one time.
/// Reached as ``NostrClient/events``.
///
/// Implements the ``NostrEventPublishing`` and ``NostrEventFetching`` primitives over the client's
/// signer and relay pool, and inherits every convenience from their extensions. Each `publish*`
/// helper signs through the configured signer — local or remote NIP-46 — and broadcasts to the
/// whole pool; ``NostrEventPublishing/publish(_:to:strategy:)-(EventTemplate,Set<RelayURL>?,_)`` signs and sends a
/// template of your own, and ``NostrEventPublishing/publish(_:to:strategy:)-(Event,Set<RelayURL>?,_)`` an
/// already-signed event, to the whole pool or to chosen relays. Use
/// ``NostrRoutingAPI/publishGossip(_:strategy:)`` instead to route by NIP-65, and
/// ``NostrSubscriptionsAPI`` for live streams rather than one-time fetches.
public struct NostrEventsAPI: NostrEventPublishing, NostrEventFetching {
    let client: NostrClient

    // MARK: - Publishing

    /// Signs `template` with the configured signer and publishes it to the whole pool (nil) or to the
    /// given relays.
    @discardableResult
    public func publish(
        _ template: EventTemplate,
        to relayURLs: Set<RelayURL>?,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let event = try await client.sign(template)
        let result = try await client.pool.publish(event, to: relayURLs, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes an already-signed event to the whole pool (nil) or to the given relays.
    @discardableResult
    public func publish(
        _ event: Event,
        to relayURLs: Set<RelayURL>?,
        strategy: PublishStrategy?
    ) async throws -> PublishResult {
        try await client.pool.publish(event, to: relayURLs, strategy: strategy)
    }

    // MARK: - Fetching

    /// Fetches events matching `filters` from the whole pool (nil) or the given relays.
    public func fetch(
        filters: [Filter],
        from relayURLs: Set<RelayURL>?,
        timeout: Duration?
    ) async throws -> [Event] {
        try await client.fetch(filters: filters, fromURLs: relayURLs, timeout: timeout)
    }

    /// Requests the NIP-45 count of events matching `filters` from the whole pool (nil) or the
    /// given relays, returning the highest count reported.
    public func countEvents(
        matching filters: [Filter],
        from relayURLs: Set<RelayURL>?,
        timeout: Duration?
    ) async throws -> Int {
        let results = try await client.pool.countEvents(matching: filters, from: relayURLs, timeout: timeout)
        return results.values.map(\.value).max() ?? 0
    }
}
