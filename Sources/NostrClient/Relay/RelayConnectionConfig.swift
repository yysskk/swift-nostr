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

    /// Combined operation timeout in seconds.
    /// Reads as the worst case of `sendTimeout` and `publishAckTimeout`;
    /// writes fan out to `sendTimeout`, `publishAckTimeout`, and `pingInterval`.
    @available(
        *, deprecated,
        message: "Split into sendTimeout, publishAckTimeout, and pingInterval"
    )
    public var operationTimeout: TimeInterval {
        get { max(sendTimeout, publishAckTimeout) }
        set {
            sendTimeout = newValue
            publishAckTimeout = newValue
            pingInterval = newValue
        }
    }

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

    /// Creates a configuration from the legacy combined operation timeout.
    /// `operationTimeout` is applied to `sendTimeout`, `publishAckTimeout`, and `pingInterval`.
    @available(
        *, deprecated,
        message:
            "operationTimeout has been split; use init(connectionTimeout:sendTimeout:publishAckTimeout:pingInterval:...)"
    )
    public init(
        connectionTimeout: TimeInterval = 10,
        operationTimeout: TimeInterval,
        autoReconnect: Bool = true,
        maxReconnectAttempts: Int = 0,
        initialReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 60,
        reconnectBackoffMultiplier: Double = 2.0
    ) {
        self.init(
            connectionTimeout: connectionTimeout,
            sendTimeout: operationTimeout,
            publishAckTimeout: operationTimeout,
            pingInterval: operationTimeout,
            autoReconnect: autoReconnect,
            maxReconnectAttempts: maxReconnectAttempts,
            initialReconnectDelay: initialReconnectDelay,
            maxReconnectDelay: maxReconnectDelay,
            reconnectBackoffMultiplier: reconnectBackoffMultiplier
        )
    }
}
