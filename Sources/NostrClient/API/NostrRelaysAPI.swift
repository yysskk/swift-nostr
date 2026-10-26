import Foundation
import NostrCore

/// Membership and connection lifecycle of the client's relay pool.
/// Reached as ``NostrClient/relays``.
///
/// This is the single relay entry point on the client: the high-level operations are here, and
/// ``pool`` exposes the underlying ``RelayPool`` for the per-relay work this namespace does not
/// wrap (per-relay publish results, NIP-45 counts per relay, individual ``RelayConnection``
/// state).
public struct NostrRelaysAPI: NostrRelayManaging {
    let client: NostrClient

    /// The relay pool backing the client.
    ///
    /// Use it for the per-relay detail this namespace deliberately flattens — for example
    /// ``RelayPool/countEvents(matching:from:timeout:)`` per relay rather than
    /// ``NostrEventsAPI/countEvents(matching:from:timeout:)``'s single best estimate.
    ///
    /// Only on the concrete namespace, not on ``NostrRelayManaging``: the pool carries publish,
    /// subscribe, and count too, which a relay-management dependency has no business reaching.
    public var pool: RelayPool { client.pool }

    // MARK: - Membership

    /// Adds a relay, optionally with a per-relay connection configuration.
    ///
    /// Relay URLs compare by their canonical form, so re-adding the same relay under a different
    /// spelling returns the existing connection (its `config` is ignored).
    @discardableResult
    public func add(_ url: RelayURL, config: RelayConnectionConfig? = nil) async -> RelayConnection {
        await client.pool.addRelay(url, config: config)
    }

    /// Adds multiple relays, each with the pool's default connection configuration.
    public func add(_ urls: some Sequence<RelayURL>) async {
        await client.pool.addRelays(Array(urls))
    }

    /// Removes a relay from the pool, disconnecting it; removing an absent relay is a no-op.
    public func remove(_ url: RelayURL) async {
        await client.pool.removeRelay(url)
    }

    // MARK: - Connection lifecycle

    /// Connects to all relays in the pool.
    public func connect() async throws {
        _ = try await client.pool.connectAll()
    }

    /// Adds the given relays and connects to all relays in the pool —
    /// the one-step form of `add(_:)` followed by `connect()`.
    ///
    /// ```swift
    /// try await client.relays.connect(to: [
    ///     RelayURL(string: "wss://relay.example.com"),
    ///     RelayURL(string: "wss://relay2.example.com"),
    /// ])
    /// ```
    /// - Throws: ``NostrError/connectionFailed(_:)`` if every relay in the pool fails to
    ///   connect; partial connection failures are tolerated.
    public func connect(to urls: some Sequence<RelayURL>) async throws {
        await add(urls)
        try await connect()
    }

    /// Disconnects from all relays, ending every open subscription.
    ///
    /// A subscription cannot outlive the connections that feed it: disconnecting drops the pool's
    /// listener tasks and nothing recreates them. Every open ``SubscriptionSequence`` therefore
    /// finishes, so a `for await` over one ends here rather than waiting on events that can no
    /// longer arrive. Reconnecting with ``connect()`` restores the relays; the subscriptions have
    /// to be opened again.
    public func disconnect() async {
        await client.disconnectAllRelays()
    }

    // MARK: - Inspection

    /// Every relay connection in the pool, in no guaranteed order.
    public var connections: [RelayConnection] {
        get async { await client.pool.connections }
    }

    /// The number of relays in the pool, connected or not.
    public var relayCount: Int {
        get async { await client.pool.relayCount }
    }

    /// The number of relays currently connected.
    public func connectedRelayCount() async -> Int {
        await client.pool.connectedRelayCount()
    }

    /// The pool's connection for a relay URL, or nil when it is not in the pool.
    public func relay(for url: RelayURL) async -> RelayConnection? {
        await client.pool.relay(for: url)
    }

    /// Clears every subscription's event deduplication cache in the relay pool.
    public func clearDeduplicationCache() async {
        await client.pool.clearDeduplicationCache()
    }
}
