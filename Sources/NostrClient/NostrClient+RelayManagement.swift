import Foundation
import NostrCore

// MARK: - Relay Management
extension NostrClient {
    /// Adds a relay, optionally with a per-relay connection configuration.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when `urlString` is not a valid
    ///   WebSocket relay URL.
    @discardableResult
    public func addRelay(_ urlString: String, config: RelayConnectionConfig? = nil) async throws -> RelayConnection {
        try await relayPool.addRelay(urlString, config: config)
    }

    /// Adds multiple relays.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` on the first invalid string.
    public func addRelays(_ urlStrings: [String]) async throws {
        for urlString in urlStrings {
            _ = try await relayPool.addRelay(urlString)
        }
    }

    /// Removes a relay from the pool, disconnecting it; removing an absent relay is a no-op.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when `urlString` is not a valid
    ///   WebSocket relay URL.
    public func removeRelay(_ urlString: String) async throws {
        try await relayPool.removeRelay(urlString)
    }

    /// Connects to all relays
    public func connect() async throws {
        try await relayPool.connectAll()
    }

    /// Adds the given relays and connects to all relays in the pool —
    /// the one-step form of `addRelays` followed by `connect()`.
    ///
    /// ```swift
    /// try await client.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])
    /// ```
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` if any URL string is invalid (before
    ///   any connection attempt), or ``NostrError/connectionFailed(_:)`` if every relay
    ///   in the pool fails to connect; partial connection failures are tolerated.
    public func connect(to urlStrings: [String]) async throws {
        try await addRelays(urlStrings)
        try await connect()
    }

    /// Disconnects from all relays
    public func disconnect() async {
        await relayPool.disconnectAll()
    }

    /// Clears the event deduplication cache in the relay pool
    public func clearDeduplicationCache() async {
        await relayPool.clearDeduplicationCache()
    }
}
