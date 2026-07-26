import Foundation
import NostrCore

// MARK: - Standard Lists (NIP-51)
extension NostrClient {
    /// Signs and publishes a NIP-51 list, replacing the current list of that kind.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishList(_ list: NostrList, strategy: PublishStrategy? = nil) async throws -> PublishedEvent {
        let event = try await withSigner { signer, publicKey in
            let content = try await sealPrivateItems(list.privateItems, with: signer, ownPubkey: publicKey)
            return try await signer.sign(.list(pubkey: publicKey, list, encryptedContent: content))
        }
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
        let target = try pubkey ?? requiredPublicKey()
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
            return try await openList(newest)
        }
        return NostrList(event: newest)
    }

    /// Reads a list event authored by the current user, decrypting its private items.
    private func openList(_ event: Event) async throws -> NostrList {
        var list = NostrList(event: event)
        list.privateItems = try await openPrivateItems(event.content)
        return list
    }
}

// MARK: - Sets (NIP-51)
extension NostrClient {
    /// Signs and publishes a NIP-51 set, replacing any prior set with the same kind and `d`
    /// identifier.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSet(
        _ set: NostrListSet,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        let event = try await withSigner { signer, publicKey in
            let content = try await sealPrivateItems(set.privateItems, with: signer, ownPubkey: publicKey)
            return try await signer.sign(.set(pubkey: publicKey, set, encryptedContent: content))
        }
        let result = try await relayPool.publish(event, strategy: strategy)
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
        let target = try pubkey ?? requiredPublicKey()
        var filter = Filter(authors: [target], kinds: [kind])
        filter.addTagQuery("d", values: [identifier])
        let events = try await fetch(filters: [filter], timeout: timeout)
        // Addressable event: pick the newest in case multiple relays return stale copies.
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        if pubkey == nil, hasSigner {
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
        let target = try pubkey ?? requiredPublicKey()
        let events = try await fetch(
            filters: [Filter(authors: [target], kinds: [kind])],
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
        let decrypt = pubkey == nil && hasSigner
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
        let events = try await fetch(filters: [filter], timeout: timeout)
        guard let newest = events.max(by: { $0.createdAt < $1.createdAt }) else {
            return nil
        }
        return try NostrListSet(event: newest)
    }

    /// Reads a set event authored by the current user, decrypting its private items.
    private func openSet(_ event: Event) async throws -> NostrListSet {
        var set = try NostrListSet(event: event)
        set.privateItems = try await openPrivateItems(event.content)
        return set
    }
}

// MARK: - Private items (NIP-44 to the author's own key)
extension NostrClient {
    /// Seals a list's or set's private items to the author's own key, or returns empty content
    /// when there are none. Goes through the signer, so a remote NIP-46 signer seals them too.
    private func sealPrivateItems(
        _ items: [Tag], with signer: any NostrSigning, ownPubkey: String
    ) async throws -> String {
        guard let json = try ListItemCipher.plaintext(items) else { return "" }
        return try await signer.nip44Encrypt(json, to: ownPubkey)
    }

    /// Opens the self-encrypted private items of a list or set event (empty content → []).
    private func openPrivateItems(_ content: String) async throws -> [Tag] {
        guard !content.isEmpty else { return [] }
        let json = try await withSigner { signer, publicKey in
            try await signer.nip44Decrypt(content, from: publicKey)
        }
        return try ListItemCipher.items(fromJSON: json)
    }
}
