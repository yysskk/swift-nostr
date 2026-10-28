import Foundation
import NostrCore

/// Membership and connection lifecycle of the client's relay pool.
/// Reached as ``NostrClient/relays``.
///
/// This is the single relay entry point on the client: the high-level operations are here, and
/// ``pool`` exposes the underlying ``RelayPool`` for the per-relay work this namespace does not
/// wrap (per-relay publish results, NIP-45 counts per relay, individual ``RelayConnection``
/// state).
///
/// Implements the ``NostrRelayManaging`` primitives; ``NostrRelayManaging/add(_:)-(RelayURL)``,
/// ``NostrRelayManaging/add(_:)-(Sequence<RelayURL>)``, ``NostrRelayManaging/connect(to:)``, and
/// ``NostrRelayManaging/relayCount`` come from the protocol's extension.
public struct NostrRelaysAPI: NostrRelayManaging {
    let client: NostrClient

    /// The relay pool backing the client.
    ///
    /// Use it for the per-relay detail this namespace deliberately flattens — for example
    /// ``RelayPool/countEvents(matching:from:timeout:)`` per relay rather than
    /// ``NostrEventFetching/countEvents(matching:route:timeout:)``'s single best estimate.
    ///
    /// Only on the concrete namespace, not on ``NostrRelayManaging``: the pool carries publish,
    /// subscribe, and count too, which a relay-management dependency has no business reaching.
    public var pool: RelayPool { client.pool }

    // MARK: - Membership

    /// Adds a relay with a per-relay connection configuration, or the pool's default (nil).
    ///
    /// Relay URLs compare by their canonical form, so re-adding the same relay under a different
    /// spelling returns the existing connection (its `config` is ignored).
    /// - Parameters:
    ///   - url: The relay to add.
    ///   - config: The relay's connection configuration, or nil for the pool config's
    ///     ``RelayPoolConfig/defaultRelayConfig``.
    /// - Returns: The relay's connection in the pool.
    @discardableResult
    public func add(_ url: RelayURL, config: RelayConnectionConfig?) async -> RelayConnection {
        await client.pool.add(url, config: config)
    }

    /// Removes a relay from the pool, disconnecting it; removing an absent relay is a no-op.
    public func remove(_ url: RelayURL) async {
        await client.pool.remove(url)
    }

    // MARK: - Connection lifecycle

    /// Connects to all relays in the pool.
    /// - Throws: ``RelayPool/Error/allConnectionsFailed`` if every relay in the pool fails to
    ///   connect; partial connection failures are tolerated.
    public func connect() async throws(RelayPool.Error) {
        _ = try await client.pool.connect()
    }

    /// Disconnects from all relays, ending every open subscription.
    ///
    /// A subscription cannot outlive the connections that feed it: disconnecting drops the pool's
    /// listener tasks and nothing recreates them. Every open ``SubscriptionSequence`` therefore
    /// finishes, so a `for await` over one ends here rather than waiting on events that can no
    /// longer arrive. Reconnecting with ``connect()`` restores the relays; the subscriptions have
    /// to be opened again.
    public func disconnect() async {
        await client.pool.disconnect()
    }

    // MARK: - Inspection

    /// Every relay connection in the pool, in no guaranteed order.
    public var connections: [RelayConnection] {
        get async { await client.pool.connections }
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
