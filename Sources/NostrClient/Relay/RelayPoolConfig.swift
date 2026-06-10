import Foundation

/// Configuration for relay pool behavior
public struct RelayPoolConfig: Sendable {
    /// Default connection configuration for new relays
    public var defaultRelayConfig: RelayConnectionConfig

    /// Maximum size of the event deduplication cache
    public var maxDeduplicationCacheSize: Int

    /// Time-to-live for cached event IDs in seconds
    public var deduplicationCacheTTL: TimeInterval

    /// Publish strategy used when `RelayPool.publish` is called without an explicit strategy
    public var defaultPublishStrategy: PublishStrategy

    /// Default configuration
    public static let `default` = RelayPoolConfig(
        defaultRelayConfig: .default,
        maxDeduplicationCacheSize: 10000,
        deduplicationCacheTTL: 300,
        defaultPublishStrategy: .firstAck
    )

    public init(
        defaultRelayConfig: RelayConnectionConfig = .default,
        maxDeduplicationCacheSize: Int = 10000,
        deduplicationCacheTTL: TimeInterval = 300,
        defaultPublishStrategy: PublishStrategy = .firstAck
    ) {
        self.defaultRelayConfig = defaultRelayConfig
        self.maxDeduplicationCacheSize = maxDeduplicationCacheSize
        self.deduplicationCacheTTL = deduplicationCacheTTL
        self.defaultPublishStrategy = defaultPublishStrategy
    }
}
