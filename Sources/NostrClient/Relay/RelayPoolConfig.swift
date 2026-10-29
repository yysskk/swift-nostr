import Foundation
import NostrCore

/// Configuration for relay pool behavior
public struct RelayPoolConfig: Sendable, Hashable {
    /// Default connection configuration for new relays
    public var defaultRelayConfig: RelayConnectionConfig

    /// How the copies of one event arriving from several relays collapse into a single delivery,
    /// or `nil` to deliver every relay's copy.
    public var deduplication: Deduplication?

    /// Publish strategy used when `RelayPool.publish` is called without an explicit strategy
    public var defaultPublishStrategy: PublishStrategy

    /// How long a one-shot fetch or count waits for relays to finish (EOSE, or COUNT) when the
    /// call doesn't pass its own timeout.
    public var queryTimeout: Duration

    /// Default configuration
    public static let `default` = RelayPoolConfig(
        defaultRelayConfig: .default,
        deduplication: .default,
        defaultPublishStrategy: .firstAck,
        queryTimeout: .seconds(10)
    )

    /// Creates a configuration; every parameter defaults to the value ``default`` uses.
    /// - Parameters:
    ///   - defaultRelayConfig: The connection configuration for new relays.
    ///   - deduplication: How copies of one event from several relays collapse, or `nil` to
    ///     deliver every relay's copy.
    ///   - defaultPublishStrategy: The strategy `RelayPool.publish` uses without an explicit one.
    ///   - queryTimeout: How long a one-shot fetch or count waits for relays without its own
    ///     timeout.
    public init(
        defaultRelayConfig: RelayConnectionConfig = .default,
        deduplication: Deduplication? = .default,
        defaultPublishStrategy: PublishStrategy = .firstAck,
        queryTimeout: Duration = .seconds(10)
    ) {
        self.defaultRelayConfig = defaultRelayConfig
        self.deduplication = deduplication
        self.defaultPublishStrategy = defaultPublishStrategy
        self.queryTimeout = queryTimeout
    }
}

// MARK: - Deduplication

extension RelayPoolConfig {
    /// Bounds the cache of event IDs each subscription has already delivered.
    ///
    /// Dropping an entry, by eviction or expiry, only risks delivering a duplicate later, never
    /// losing an event.
    public struct Deduplication: Sendable, Hashable {
        /// The maximum number of cached event IDs across every subscription, enforced as events
        /// are received by evicting the oldest. Below 1 keeps nothing, so every copy is delivered.
        public var maximumCount: Int

        /// How long a cached event ID is remembered.
        public var timeToLive: Duration

        /// Up to 10,000 event IDs, each remembered for 5 minutes.
        public static let `default` = Deduplication()

        /// Creates a deduplication setting; every parameter defaults to the value ``default`` uses.
        /// - Parameters:
        ///   - maximumCount: The maximum number of cached event IDs across every subscription.
        ///   - timeToLive: How long a cached event ID is remembered.
        public init(maximumCount: Int = 10_000, timeToLive: Duration = .seconds(300)) {
            self.maximumCount = maximumCount
            self.timeToLive = timeToLive
        }
    }
}
