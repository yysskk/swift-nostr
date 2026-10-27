import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrRelayManaging {
    /// Adds a relay with the pool's default connection configuration.
    ///
    /// Re-adding a relay already in the pool returns the existing connection.
    /// - Parameter url: The relay to add.
    /// - Returns: The relay's connection in the pool.
    @discardableResult
    public func add(_ url: RelayURL) async -> RelayConnection {
        await add(url, config: nil)
    }
}

// MARK: - Conveniences

extension NostrRelayManaging {
    /// Adds multiple relays, in order, each with the pool's default connection configuration.
    ///
    /// Relays already in the pool keep their existing connection.
    /// - Parameter urls: The relays to add.
    public func add(_ urls: some Sequence<RelayURL>) async {
        for url in urls {
            await add(url, config: nil)
        }
    }

    /// Adds the given relays and connects to all relays in the pool — the one-step form of
    /// ``NostrRelayManaging/add(_:)-(Sequence<RelayURL>)`` followed by ``NostrRelayManaging/connect()``.
    ///
    /// ```swift
    /// try await client.relays.connect(to: [
    ///     RelayURL(string: "wss://relay.example.com"),
    ///     RelayURL(string: "wss://relay2.example.com"),
    /// ])
    /// ```
    /// - Parameter urls: The relays to add before connecting.
    /// - Throws: ``RelayPool/Error/allConnectionsFailed`` if every relay in the pool fails to
    ///   connect; partial connection failures are tolerated.
    public func connect(to urls: some Sequence<RelayURL>) async throws(RelayPool.Error) {
        await add(urls)
        try await connect()
    }

    /// The number of relays in the pool, connected or not.
    public var relayCount: Int {
        get async { await connections.count }
    }
}
