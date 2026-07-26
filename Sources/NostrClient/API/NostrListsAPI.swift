import Foundation
import NostrCore

/// NIP-51 lists (one per kind) and sets (many per kind, keyed by a `d` identifier).
/// Reached as ``NostrClient/lists``.
///
/// Private items are NIP-44-encrypted to the author's own key through the configured signer,
/// local or remote. Fetching your own list or set decrypts them; fetching someone else's
/// returns only its public items.
public struct NostrListsAPI: NostrListManaging {
    let client: NostrClient

    // MARK: - Lists

    /// Signs and publishes a NIP-51 list, replacing the current list of that kind.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publish(_ list: NostrList, strategy: PublishStrategy? = nil) async throws -> PublishedEvent {
        let event = try await client.withSigner { signer, publicKey in
            let content = try await Self.sealPrivateItems(list.privateItems, with: signer, ownPubkey: publicKey)
            return try await signer.sign(.list(pubkey: publicKey, list, encryptedContent: content))
        }
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches the newest list of `kind`. With no `pubkey` it fetches the current user's list
    /// and decrypts private items; for another pubkey only public items are returned.
    /// - Throws: when fetching the current user's own list and its private content cannot be
    ///   decrypted (republishing such a list would silently drop the private items).
    /// - Returns: The list, or nil if none was found.
    public func fetch(
        kind: Event.Kind,
        for pubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> NostrList? {
        let target = try await author(pubkey)
        let events = try await client.fetch(
            filters: [Filter(authors: [target], kinds: [kind], limit: 1)],
            toURLs: nil,
            timeout: timeout
        )
        // Replaceable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        // Only the author can decrypt private items — do so when fetching the current user's
        // own list, and surface a decrypt failure so a subsequent republish cannot silently
        // drop the private items.
        if pubkey == nil, await client.hasSigner {
            return try await openList(newest)
        }
        return NostrList(event: newest)
    }

    // MARK: - Sets

    /// Signs and publishes a NIP-51 set, replacing any prior set with the same kind and `d`
    /// identifier.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSet(
        _ set: NostrListSet,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try await client.withSigner { signer, publicKey in
            let content = try await Self.sealPrivateItems(set.privateItems, with: signer, ownPubkey: publicKey)
            return try await signer.sign(.set(pubkey: publicKey, set, encryptedContent: content))
        }
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches one set by kind and `d` identifier. With no `pubkey` it fetches the current
    /// user's set and decrypts its private items; for another pubkey only public items are
    /// returned.
    /// - Throws: when fetching the current user's own set and its private content cannot be
    ///   decrypted (republishing such a set would silently drop the private items).
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for pubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> NostrListSet? {
        let target = try await author(pubkey)
        var filter = Filter(authors: [target], kinds: [kind])
        filter.addTagQuery("d", values: [identifier])
        let events = try await client.fetch(filters: [filter], toURLs: nil, timeout: timeout)
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        if pubkey == nil, await client.hasSigner {
            return try await openSet(newest)
        }
        return try NostrListSet(event: newest)
    }

    /// Fetches all sets of a kind for an author, keeping the newest per `d` identifier. With no
    /// `pubkey` it fetches the current user's sets and decrypts their private items; for another
    /// pubkey only public items are returned.
    /// - Throws: when fetching the current user's own sets and a set's private content cannot be
    ///   decrypted.
    public func fetchSets(
        kind: Event.Kind,
        for pubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> [NostrListSet] {
        let target = try await author(pubkey)
        let events = try await client.fetch(
            filters: [Filter(authors: [target], kinds: [kind])],
            toURLs: nil,
            timeout: timeout
        )
        // Addressable events: keep the newest event per `d` identifier, ignoring any without one.
        var newestByIdentifier: [String: Event] = [:]
        for event in events {
            guard let identifier = event.firstTagValue(named: "d") else { continue }
            if let existing = newestByIdentifier[identifier], existing.createdAt >= event.createdAt {
                continue
            }
            newestByIdentifier[identifier] = event
        }
        let decrypt = pubkey == nil ? await client.hasSigner : false
        var sets: [NostrListSet] = []
        for event in newestByIdentifier.values {
            sets.append(decrypt ? try await openSet(event) : try NostrListSet(event: event))
        }
        return sets
    }

    /// Fetches the set addressed by a NIP-19 `naddr`.
    ///
    /// Only public items are returned; the current user's private items are available via
    /// ``fetchSet(kind:identifier:for:timeout:)`` with no `pubkey`.
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(naddr: NAddr, timeout: TimeInterval = 10) async throws -> NostrListSet? {
        var filter = Filter(authors: [naddr.author], kinds: [Event.Kind(rawValue: naddr.kind)])
        filter.addTagQuery("d", values: [naddr.identifier])
        let events = try await client.fetch(filters: [filter], toURLs: nil, timeout: timeout)
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return try NostrListSet(event: newest)
    }

    // MARK: - Private items (NIP-44 to the author's own key)

    /// The author to query: the given pubkey, or the signer's own when none is given.
    /// - Throws: ``NostrError/signerNotSet`` when neither is available.
    private func author(_ pubkey: String?) async throws -> String {
        if let pubkey { return pubkey }
        return try await client.requiredPublicKey()
    }

    /// Reads a list event authored by the current user, decrypting its private items.
    private func openList(_ event: Event) async throws -> NostrList {
        var list = NostrList(event: event)
        list.privateItems = try await openPrivateItems(event.content)
        return list
    }

    /// Reads a set event authored by the current user, decrypting its private items.
    private func openSet(_ event: Event) async throws -> NostrListSet {
        var set = try NostrListSet(event: event)
        set.privateItems = try await openPrivateItems(event.content)
        return set
    }

    /// Seals a list's or set's private items to the author's own key, or returns empty content
    /// when there are none. Goes through the signer, so a remote NIP-46 signer seals them too.
    private static func sealPrivateItems(
        _ items: [Tag], with signer: any NostrSigning, ownPubkey: String
    ) async throws -> String {
        guard let json = try ListItemCipher.plaintext(items) else { return "" }
        return try await signer.nip44Encrypt(json, to: ownPubkey)
    }

    /// Opens the self-encrypted private items of a list or set event (empty content → []).
    private func openPrivateItems(_ content: String) async throws -> [Tag] {
        guard !content.isEmpty else { return [] }
        let json = try await client.withSigner { signer, publicKey in
            try await signer.nip44Decrypt(content, from: publicKey)
        }
        return try ListItemCipher.items(fromJSON: json)
    }
}
