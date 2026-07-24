import Foundation
import NostrCore

// MARK: - Simple Group List (NIP-51 kind 10009)
extension NostrClient {
    /// Fetches the newest kind-10009 simple group list — the NIP-29 groups a user is in.
    ///
    /// With no `pubkey` it fetches the current user's list and decrypts private entries;
    /// for another pubkey only public entries are returned. A thin typed wrapper over
    /// ``fetchList(kind:for:timeout:)`` with the same throwing behavior: fetching the
    /// current user's own list needs the local signer holding the NIP-44 key and throws
    /// when the list's private content cannot be decrypted (republishing such a list
    /// would silently drop the private entries).
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    ///
    /// - Parameters:
    ///   - pubkey: The list's author; nil (the default) fetches the current user's list.
    ///   - timeout: How long to wait for the relays' EOSE (default: 10 seconds).
    /// - Returns: The typed list, or nil if none was found.
    public func fetchSimpleGroupList(
        for pubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> SimpleGroupList? {
        guard let list = try await fetchList(kind: .simpleGroupList, for: pubkey, timeout: timeout) else {
            return nil
        }
        return try SimpleGroupList(list: list)
    }

    /// Signs and publishes the list (kind 10009), replacing the user's current simple
    /// group list.
    ///
    /// Unlike the group flows, which target a group's single relay, this broadcasts to
    /// the whole pool — a replaceable list lives everywhere, so every relay carrying the
    /// user's events receives the fresh copy. Wraps ``publishList(_:strategy:)``,
    /// inheriting its local-signer requirement: private entries are NIP-44-encrypted with
    /// the local key, so a remote signer throws ``NostrError/localSignerRequired`` (and no
    /// signer, ``NostrError/signerNotSet``).
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    ///
    /// - Parameters:
    ///   - list: The list to publish.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSimpleGroupList(
        _ list: SimpleGroupList,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publishList(list.list, strategy: strategy)
    }
}
