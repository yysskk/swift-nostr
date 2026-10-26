import Foundation
import NostrCore

/// Configuration for relay pool behavior
public struct RelayPoolConfig: Sendable {
    /// Default connection configuration for new relays
    public var defaultRelayConfig: RelayConnectionConfig

    /// Maximum number of cached event IDs across every subscription, enforced as events are
    /// received by evicting the oldest. Below 1 turns deduplication off.
    public var maxDeduplicationCacheSize: Int

    /// How long a cached event ID is remembered.
    public var deduplicationCacheTTL: Duration

    /// Publish strategy used when `RelayPool.publish` is called without an explicit strategy
    public var defaultPublishStrategy: PublishStrategy

    /// How long a one-shot fetch or count waits for relays to finish (EOSE, or COUNT) when the
    /// call doesn't pass its own timeout.
    public var queryTimeout: Duration

    /// Default configuration
    public static let `default` = RelayPoolConfig(
        defaultRelayConfig: .default,
        maxDeduplicationCacheSize: 10000,
        deduplicationCacheTTL: .seconds(300),
        defaultPublishStrategy: .firstAck,
        queryTimeout: .seconds(10)
    )

    /// Creates a configuration; every parameter defaults to the value ``default`` uses.
    /// - Parameters:
    ///   - defaultRelayConfig: The connection configuration for new relays.
    ///   - maxDeduplicationCacheSize: The maximum number of cached event IDs, or below 1 to turn
    ///     deduplication off.
    ///   - deduplicationCacheTTL: How long a cached event ID is remembered.
    ///   - defaultPublishStrategy: The strategy `RelayPool.publish` uses without an explicit one.
    ///   - queryTimeout: How long a one-shot fetch or count waits for relays without its own
    ///     timeout.
    public init(
        defaultRelayConfig: RelayConnectionConfig = .default,
        maxDeduplicationCacheSize: Int = 10000,
        deduplicationCacheTTL: Duration = .seconds(300),
        defaultPublishStrategy: PublishStrategy = .firstAck,
        queryTimeout: Duration = .seconds(10)
    ) {
        self.defaultRelayConfig = defaultRelayConfig
        self.maxDeduplicationCacheSize = maxDeduplicationCacheSize
        self.deduplicationCacheTTL = deduplicationCacheTTL
        self.defaultPublishStrategy = defaultPublishStrategy
        self.queryTimeout = queryTimeout
    }
}
