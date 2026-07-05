import Foundation
import NostrCore

// MARK: - Long-form Content (NIP-23)
extension NostrClient {
    /// Signs and publishes a long-form article; the same identifier replaces the previous version.
    /// - Parameter draft: Publishes as a kind 30024 draft instead of a kind 30023 article.
    /// - Parameter strategy: How many relay acknowledgments to wait for before returning
    ///   (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishLongFormContent(
        _ article: LongFormContent,
        draft: Bool = false,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try withSigner { try $0.signLongFormContent(article, draft: draft) }
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches an article by author and identifier, keeping the newest copy across relays.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(
        author: String,
        identifier: String,
        timeout: TimeInterval = 10
    ) async throws -> LongFormContent? {
        var filter = Filter(authors: [author], kinds: [.longFormContent])
        filter.addTagQuery("d", values: [identifier])
        let events = try await fetch(filters: [filter], timeout: timeout)
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return LongFormContent(event: newest)
    }

    /// Fetches the article addressed by an `naddr` coordinate.
    ///
    /// Any relay hints carried by the coordinate are used only when they are already in the pool;
    /// otherwise the whole pool is queried.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(naddr: NAddr, timeout: TimeInterval = 10) async throws -> LongFormContent? {
        var filter = Filter(authors: [naddr.author], kinds: [Event.Kind(rawValue: naddr.kind)])
        filter.addTagQuery("d", values: [naddr.identifier])

        // Use the coordinate's relay hints only where they are already connected in the pool.
        var hinted: Set<URL> = []
        for relay in naddr.relays {
            guard let url = URL(string: relay) else { continue }
            if await relayPool.relay(for: url) != nil {
                hinted.insert(url)
            }
        }

        let events = try await fetch(filters: [filter], to: hinted.isEmpty ? nil : hinted, timeout: timeout)
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return LongFormContent(event: newest)
    }
}
