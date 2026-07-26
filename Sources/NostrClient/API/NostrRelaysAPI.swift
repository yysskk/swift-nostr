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
    /// ``RelayPool/count(filters:to:timeout:)`` per relay rather than
    /// ``NostrEventsAPI/count(filters:to:timeout:)``'s single best estimate.
    ///
    /// Only on the concrete namespace, not on ``NostrRelayManaging``: the pool carries publish,
    /// subscribe, and count too, which a relay-management dependency has no business reaching.
    public var pool: RelayPool { client.pool }

    // MARK: - Membership

    /// Adds a relay, optionally with a per-relay connection configuration.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when `urlString` is not a valid
    ///   WebSocket relay URL.
    @discardableResult
    public func add(_ urlString: String, config: RelayConnectionConfig? = nil) async throws -> RelayConnection {
        try await client.pool.addRelay(urlString, config: config)
    }

    /// Adds multiple relays.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` on the first invalid string.
    public func add(_ urlStrings: [String]) async throws {
        try await client.pool.addRelays(urlStrings)
    }

    /// Removes a relay from the pool, disconnecting it; removing an absent relay is a no-op.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when `urlString` is not a valid
    ///   WebSocket relay URL.
    public func remove(_ urlString: String) async throws {
        try await client.pool.removeRelay(urlString)
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
    /// try await client.relays.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])
    /// ```
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` if any URL string is invalid (before
    ///   any connection attempt), or ``NostrError/connectionFailed(_:)`` if every relay
    ///   in the pool fails to connect; partial connection failures are tolerated.
    public func connect(to urlStrings: [String]) async throws {
        try await add(urlStrings)
        try await connect()
    }

    /// Disconnects from all relays.
    public func disconnect() async {
        await client.pool.disconnectAll()
    }

    // MARK: - Inspection

    /// Every relay connection in the pool, in no guaranteed order.
    public var connections: [RelayConnection] {
        get async { await client.pool.connections }
    }

    /// The number of relays in the pool, connected or not.
    public var count: Int {
        get async { await client.pool.count }
    }

    /// The number of relays currently connected.
    public func connectedCount() async -> Int {
        await client.pool.connectedCount()
    }

    /// The pool's connection for a relay URL, or nil when it is not in the pool.
    public func relay(for url: URL) async -> RelayConnection? {
        await client.pool.relay(for: url)
    }

    /// Clears every subscription's event deduplication cache in the relay pool.
    public func clearDeduplicationCache() async {
        await client.pool.clearDeduplicationCache()
    }
}
