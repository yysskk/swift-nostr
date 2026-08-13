import Foundation

/// Configuration for relay connection behavior
public struct RelayConnectionConfig: Sendable {
    /// Connection timeout in seconds. Also bounds the pong wait of keepalive pings.
    public var connectionTimeout: TimeInterval

    /// Timeout for sending a single WebSocket frame in seconds
    public var sendTimeout: TimeInterval

    /// How long a publish waits for the relay's OK response in seconds
    public var publishAckTimeout: TimeInterval

    /// Interval between keepalive pings in seconds.
    /// Liveness is detected by periodic WebSocket pings instead of an idle timeout,
    /// so a relay that simply has no messages to deliver is never torn down.
    public var pingInterval: TimeInterval

    /// Whether to automatically reconnect on failure
    public var autoReconnect: Bool

    /// Maximum number of reconnection attempts (0 = unlimited)
    public var maxReconnectAttempts: Int

    /// Initial delay before first reconnection attempt in seconds
    public var initialReconnectDelay: TimeInterval

    /// Maximum delay between reconnection attempts in seconds
    public var maxReconnectDelay: TimeInterval

    /// Multiplier for exponential backoff
    public var reconnectBackoffMultiplier: Double

    /// Default configuration
    public static let `default` = RelayConnectionConfig()

    public init(
        connectionTimeout: TimeInterval = 10,
        sendTimeout: TimeInterval = 10,
        publishAckTimeout: TimeInterval = 30,
        pingInterval: TimeInterval = 30,
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 0,
        initialReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 60,
        reconnectBackoffMultiplier: Double = 2.0
    ) {
        self.connectionTimeout = connectionTimeout
        self.sendTimeout = sendTimeout
        self.publishAckTimeout = publishAckTimeout
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
    public static let minimumReconnectDelay: TimeInterval = 0.1

    /// The delay to wait before the first reconnection attempt, floored so it always pauses.
    ///
    /// Resolved where it is read rather than in the initializer: every configuration field is a
    /// `var`, so a value set afterwards would otherwise bypass validation done at init time.
    var resolvedInitialReconnectDelay: TimeInterval {
        max(initialReconnectDelay, Self.minimumReconnectDelay)
    }

    /// The ceiling for reconnect delays, never below the initial delay.
    var resolvedMaxReconnectDelay: TimeInterval {
        max(maxReconnectDelay, resolvedInitialReconnectDelay)
    }

    /// The backoff multiplier, floored at 1 so a delay can hold steady but never shrink.
    ///
    /// A multiplier of exactly 1 is a legitimate choice — retrying at a fixed rate — so it is left
    /// alone. Anything below it would walk the delay back toward zero.
    var resolvedBackoffMultiplier: Double {
        max(reconnectBackoffMultiplier, 1)
    }

    /// Applies `delay` to the ceiling, keeping every wait inside the configured bounds.
    func boundedReconnectDelay(_ delay: TimeInterval) -> TimeInterval {
        min(max(delay, Self.minimumReconnectDelay), resolvedMaxReconnectDelay)
    }
}
