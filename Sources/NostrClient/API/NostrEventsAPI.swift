import Foundation
import NostrCore

/// Authoring and publishing events, and fetching them one time.
/// Reached as ``NostrClient/events``.
///
/// Implements the ``NostrEventPublishing`` and ``NostrEventFetching`` primitives over the client's
/// signer and relay pool, and inherits every convenience from their extensions. Each `publish*`
/// helper signs through the configured signer — local or remote NIP-46 — and broadcasts to the
/// whole pool; ``NostrEventPublishing/publish(_:route:strategy:)-(EventTemplate,_,_)`` signs and sends a
/// template of your own, and ``NostrEventPublishing/publish(_:route:strategy:)-(Event,_,_)`` an
/// already-signed event, along any ``RelayRoute`` — the whole pool, chosen relays, or the NIP-65
/// outbox. Use ``NostrSubscriptionsAPI`` for live streams rather than one-time fetches.
public struct NostrEventsAPI: NostrEventPublishing, NostrEventFetching {
    let client: NostrClient

    // MARK: - Publishing

    /// Signs `template` with the configured signer and publishes it along `route`.
    @discardableResult
    public func publish(
        _ template: EventTemplate,
        route: RelayRoute,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let event = try await client.sign(template)
        let result = try await publish(event, route: route, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes an already-signed event along `route`.
    @discardableResult
    public func publish(
        _ event: Event,
        route: RelayRoute,
        strategy: PublishStrategy?
    ) async throws -> PublishResult {
        let relayURLs = await client.routing.relayURLs(publishing: event, along: route)
        return try await client.pool.publish(event, to: relayURLs, strategy: strategy)
    }

    // MARK: - Fetching

    /// Fetches events matching `filters` along `route`.
    public func fetch(
        filters: [Filter],
        route: RelayRoute,
        timeout: Duration?
    ) async throws -> [Event] {
        let relayURLs = await client.routing.relayURLs(reading: filters, along: route)
        return try await client.fetch(filters: filters, fromURLs: relayURLs, timeout: timeout)
    }

    /// Requests the NIP-45 count of events matching `filters` along `route`, returning the highest
    /// count reported.
    public func countEvents(
        matching filters: [Filter],
        route: RelayRoute,
        timeout: Duration?
    ) async throws -> Int {
        let relayURLs = await client.routing.relayURLs(reading: filters, along: route)
        let results = try await client.pool.countEvents(matching: filters, from: relayURLs, timeout: timeout)
        return results.values.map(\.value).max() ?? 0
    }
}
