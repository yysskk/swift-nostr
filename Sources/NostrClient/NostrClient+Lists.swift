import Foundation
import NostrCore

// MARK: - Standard Lists (NIP-51)
extension NostrClient {
    /// Signs and publishes a NIP-51 list, replacing the current list of that kind.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishList(_ list: NostrList, strategy: PublishStrategy? = nil) async throws -> PublishedEvent {
        let event = try withSigner { try $0.signList(list) }
        let result = try await relayPool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches the newest list of `kind`. With no `pubkey` it fetches the current user's list
    /// and decrypts private items; for another pubkey only public items are returned.
    /// - Throws: when fetching the current user's own list and its private content cannot be
    ///   decrypted (republishing such a list would silently drop the private items).
    /// - Returns: The list, or nil if none was found.
    public func fetchList(
        kind: Event.Kind,
        for pubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> NostrList? {
        let target = try pubkey ?? withSigner { $0.publicKey }
        let events = try await fetch(
            filters: [Filter(authors: [target], kinds: [kind], limit: 1)],
            timeout: timeout
        )
        // Replaceable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        // Only the author can decrypt private items — do so when fetching the current user's
        // own list, and surface a decrypt failure so a subsequent republish cannot silently
        // drop the private items.
        if pubkey == nil, hasSigner {
            return try withSigner { try $0.openList(newest) }
        }
        return NostrList(event: newest)
    }
}
