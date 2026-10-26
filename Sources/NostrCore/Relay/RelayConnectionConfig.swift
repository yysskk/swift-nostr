import Foundation

/// Configuration for relay connection behavior
public struct RelayConnectionConfig: Sendable {
    /// How long opening the connection may take. Also bounds the pong wait of keepalive pings.
    public var connectionTimeout: Duration

    /// How long sending a single WebSocket frame may take.
    public var sendTimeout: Duration

    /// How long a publish waits for the relay's OK response.
    public var publishAckTimeout: Duration

    /// How long ``RelayConnection/count(filters:timeout:)`` waits for the relay's COUNT response
    /// when the call doesn't pass its own timeout.
    public var queryTimeout: Duration

    /// The interval between keepalive pings.
    /// Liveness is detected by periodic WebSocket pings instead of an idle timeout,
    /// so a relay that simply has no messages to deliver is never torn down.
    public var pingInterval: Duration

    /// Whether to automatically reconnect on failure
    public var autoReconnect: Bool

    /// Maximum number of reconnection attempts (0 = unlimited)
    public var maxReconnectAttempts: Int

    /// The delay before the first reconnection attempt.
    public var initialReconnectDelay: Duration

    /// The longest delay between reconnection attempts.
    public var maxReconnectDelay: Duration

    /// Multiplier for exponential backoff
    public var reconnectBackoffMultiplier: Double

    /// Default configuration
    public static let `default` = RelayConnectionConfig()

    /// Creates a configuration; every parameter defaults to the value ``default`` uses.
    /// - Parameters:
    ///   - connectionTimeout: How long opening the connection may take.
    ///   - sendTimeout: How long sending a single WebSocket frame may take.
    ///   - publishAckTimeout: How long a publish waits for the relay's OK response.
    ///   - queryTimeout: How long a count waits for the relay's response without its own timeout.
    ///   - pingInterval: The interval between keepalive pings.
    ///   - autoReconnect: Whether to reconnect automatically on failure.
    ///   - maxReconnectAttempts: The maximum number of reconnection attempts, or 0 for unlimited.
    ///   - initialReconnectDelay: The delay before the first reconnection attempt.
    ///   - maxReconnectDelay: The longest delay between reconnection attempts.
    ///   - reconnectBackoffMultiplier: The factor each reconnect delay grows by.
    public init(
        connectionTimeout: Duration = .seconds(10),
        sendTimeout: Duration = .seconds(10),
        publishAckTimeout: Duration = .seconds(30),
        queryTimeout: Duration = .seconds(10),
        pingInterval: Duration = .seconds(30),
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 0,
        initialReconnectDelay: Duration = .seconds(1),
        maxReconnectDelay: Duration = .seconds(60),
        reconnectBackoffMultiplier: Double = 2.0
    ) {
        self.connectionTimeout = connectionTimeout
        self.sendTimeout = sendTimeout
        self.publishAckTimeout = publishAckTimeout
        self.queryTimeout = queryTimeout
        self.pingInterval = pingInterval
        self.autoReconnect = autoReconnect
        self.maxReconnectAttempts = maxReconnectAttempts
        self.initialReconnectDelay = initialReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.reconnectBackoffMultiplier = reconnectBackoffMultiplier
    }

}

// MARK: - Reconnection Bounds

extension RelayConnectionConfig {
    /// The shortest a reconnect delay is allowed to be.
    ///
    /// `initialReconnectDelay: 0` reads like "reconnect immediately", but zero multiplied by any
    /// backoff stays zero — with the default of unlimited attempts that is an unbounded loop
    /// hammering the relay with no pause at all. A negative delay does the same, since
    /// `Task.sleep` of one returns at once.
    public static let minimumReconnectDelay: Duration = .milliseconds(100)

    /// The delay to wait before the first reconnection attempt, floored so it always pauses.
    ///
    /// Resolved where it is read rather than in the initializer: every configuration field is a
    /// `var`, so a value set afterwards would otherwise bypass validation done at init time.
    var resolvedInitialReconnectDelay: Duration {
        max(initialReconnectDelay, Self.minimumReconnectDelay)
    }

    /// The ceiling for reconnect delays, never below the initial delay.
    var resolvedMaxReconnectDelay: Duration {
        max(maxReconnectDelay, resolvedInitialReconnectDelay)
    }

    /// The backoff multiplier, floored at 1 so a delay can hold steady but never shrink.
    ///
    /// A multiplier of exactly 1 is a legitimate choice — retrying at a fixed rate — so it is left
    /// alone. Anything below it would walk the delay back toward zero, and NaN is treated as 1.
    var resolvedBackoffMultiplier: Double {
        reconnectBackoffMultiplier.isNaN ? 1 : max(reconnectBackoffMultiplier, 1)
    }

    /// The delay that follows `delay`: grown by the backoff multiplier and kept inside the bounds.
    ///
    /// Multiplying a `Duration` by an infinite or very large factor traps, so the growth is checked
    /// against the ceiling in floating point first and only multiplied exactly when it stays below.
    func nextReconnectDelay(after delay: Duration) -> Duration {
        let multiplier = resolvedBackoffMultiplier
        let ceiling = resolvedMaxReconnectDelay
        guard delay.timeInterval * multiplier < ceiling.timeInterval else { return ceiling }
        return boundedReconnectDelay(delay * multiplier)
    }

    /// Applies `delay` to the ceiling, keeping every wait inside the configured bounds.
    func boundedReconnectDelay(_ delay: Duration) -> Duration {
        min(max(delay, Self.minimumReconnectDelay), resolvedMaxReconnectDelay)
    }
}
