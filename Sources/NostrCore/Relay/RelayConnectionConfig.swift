import Foundation

/// Configuration for relay connection behavior
public struct RelayConnectionConfig: Sendable, Hashable {
    /// How long opening the connection may take. Also bounds the pong wait of keepalive pings.
    public var connectionTimeout: Duration

    /// How long sending a single WebSocket frame may take.
    public var sendTimeout: Duration

    /// How long a publish waits for the relay's OK response.
    public var publishAckTimeout: Duration

    /// How long ``RelayConnection/countEvents(matching:timeout:)`` waits for the relay's COUNT
    /// response when the call doesn't pass its own timeout.
    public var queryTimeout: Duration

    /// The interval between keepalive pings.
    /// Liveness is detected by periodic WebSocket pings instead of an idle timeout,
    /// so a relay that simply has no messages to deliver is never torn down.
    public var pingInterval: Duration

    /// How to reconnect after the connection drops, or `nil` to never reconnect automatically.
    public var reconnect: ReconnectPolicy?

    /// Default configuration
    public static let `default` = RelayConnectionConfig()

    /// Creates a configuration; every parameter defaults to the value ``default`` uses.
    /// - Parameters:
    ///   - connectionTimeout: How long opening the connection may take.
    ///   - sendTimeout: How long sending a single WebSocket frame may take.
    ///   - publishAckTimeout: How long a publish waits for the relay's OK response.
    ///   - queryTimeout: How long a count waits for the relay's response without its own timeout.
    ///   - pingInterval: The interval between keepalive pings.
    ///   - reconnect: How to reconnect after a drop, or `nil` to never reconnect automatically.
    public init(
        connectionTimeout: Duration = .seconds(10),
        sendTimeout: Duration = .seconds(10),
        publishAckTimeout: Duration = .seconds(30),
        queryTimeout: Duration = .seconds(10),
        pingInterval: Duration = .seconds(30),
        reconnect: ReconnectPolicy? = .default
    ) {
        self.connectionTimeout = connectionTimeout
        self.sendTimeout = sendTimeout
        self.publishAckTimeout = publishAckTimeout
        self.queryTimeout = queryTimeout
        self.pingInterval = pingInterval
        self.reconnect = reconnect
    }
}

extension RelayConnectionConfig {
    /// The delay before the first reconnection attempt, or zero when automatic reconnection is off.
    var firstReconnectDelay: Duration {
        reconnect?.resolvedInitialDelay ?? .zero
    }
}
