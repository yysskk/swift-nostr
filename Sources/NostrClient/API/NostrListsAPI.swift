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
        let template = try await client.withSigner { signer, _ in
            try await EventTemplate.list(list, encryptingWith: signer)
        }
        let event = try await client.sign(template)
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches the newest list of `kind`. With no `publicKey` it fetches the current user's list
    /// and decrypts private items; for another public key only public items are returned.
    /// - Parameter timeout: How long to wait for relays to finish; `nil` uses
    ///   ``RelayPoolConfig/queryTimeout``.
    /// - Throws: when fetching the current user's own list and its private content cannot be
    ///   decrypted (republishing such a list would silently drop the private items).
    /// - Returns: The list, or nil if none was found.
    public func fetch(
        kind: Event.Kind,
        for publicKey: PublicKey? = nil,
        timeout: Duration? = nil
    ) async throws -> NostrList? {
        let target = try await author(publicKey)
        let events = try await client.fetch(
            filters: [Filter(authors: [target], kinds: [kind], limit: 1)],
            fromURLs: nil,
            timeout: timeout
        )
        // Replaceable event: pick the newest the requested author actually signed, so a stale or
        // forged copy from any relay cannot displace it.
        guard let newest = VerifiedEventSelection.newest(in: events, kind: kind, author: target) else {
            return nil
        }
        // Only the author can decrypt private items — do so when fetching the current user's
        // own list, and surface a decrypt failure so a subsequent republish cannot silently
        // drop the private items.
        if publicKey == nil, await client.hasSigner {
            return try await client.withSigner { signer, _ in
                try await NostrList(event: newest, decryptingWith: signer)
            }
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
        let template = try await client.withSigner { signer, _ in
            try await EventTemplate.set(set, encryptingWith: signer)
        }
        let event = try await client.sign(template)
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches one set by kind and `d` identifier. With no `publicKey` it fetches the current
    /// user's set and decrypts its private items; for another public key only public items are
    /// returned.
    /// - Parameter timeout: How long to wait for relays to finish; `nil` uses
    ///   ``RelayPoolConfig/queryTimeout``.
    /// - Throws: when fetching the current user's own set and its private content cannot be
    ///   decrypted (republishing such a set would silently drop the private items).
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for publicKey: PublicKey? = nil,
        timeout: Duration? = nil
    ) async throws -> NostrListSet? {
        let target = try await author(publicKey)
        var filter = Filter(authors: [target], kinds: [kind])
        filter.addTagQuery("d", values: [identifier])
        let events = try await client.fetch(filters: [filter], fromURLs: nil, timeout: timeout)
        // Addressable event: the identifier is part of its coordinates, so it is matched alongside
        // the author and kind before the newest signed copy is chosen.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: kind, author: target, identifier: identifier)
        else {
            return nil
        }
        if publicKey == nil, await client.hasSigner {
            return try await decryptedSet(newest)
        }
        return try NostrListSet(event: newest)
    }

    /// Fetches all sets of a kind for an author, keeping the newest per `d` identifier. With no
    /// `publicKey` it fetches the current user's sets and decrypts their private items; for another
    /// public key only public items are returned.
    /// - Parameter timeout: How long to wait for relays to finish; `nil` uses
    ///   ``RelayPoolConfig/queryTimeout``.
    /// - Throws: when fetching the current user's own sets and a set's private content cannot be
    ///   decrypted.
    public func fetchSets(
        kind: Event.Kind,
        for publicKey: PublicKey? = nil,
        timeout: Duration? = nil
    ) async throws -> [NostrListSet] {
        let target = try await author(publicKey)
        let events = try await client.fetch(
            filters: [Filter(authors: [target], kinds: [kind])],
            fromURLs: nil,
            timeout: timeout
        )
        // Addressable events: keep the newest event per `d` identifier, ignoring any without one.
        // Each identifier is resolved through the same selection as a single-set fetch, so a copy
        // from another author or with an unverifiable signature cannot win one of the slots.
        let identifiers = Set(events.compactMap { $0.firstTagValue(named: "d") })
        var newestByIdentifier: [String: Event] = [:]
        for identifier in identifiers {
            newestByIdentifier[identifier] = VerifiedEventSelection.newest(
                in: events, kind: kind, author: target, identifier: identifier)
        }
        let decrypt = publicKey == nil ? await client.hasSigner : false
        var sets: [NostrListSet] = []
        for event in newestByIdentifier.values {
            sets.append(decrypt ? try await decryptedSet(event) : try NostrListSet(event: event))
        }
        return sets
    }

    /// Fetches the set addressed by a NIP-19 `naddr`.
    ///
    /// Only public items are returned; the current user's private items are available via
    /// ``fetchSet(kind:identifier:for:timeout:)`` with no `publicKey`.
    /// - Parameter timeout: How long to wait for relays to finish; `nil` uses
    ///   ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(naddr: NAddr, timeout: Duration? = nil) async throws -> NostrListSet? {
        var filter = Filter(authors: [naddr.author], kinds: [Event.Kind(rawValue: naddr.kind)])
        filter.addTagQuery("d", values: [naddr.identifier])
        let events = try await client.fetch(filters: [filter], fromURLs: nil, timeout: timeout)
        guard
            let newest = VerifiedEventSelection.newest(
                in: events,
                kind: Event.Kind(rawValue: naddr.kind),
                author: naddr.author,
                identifier: naddr.identifier)
        else {
            return nil
        }
        return try NostrListSet(event: newest)
    }

    // MARK: - Private

    /// The author to query: the given public key, or the signer's own when none is given.
    /// - Throws: ``NostrError/signerNotSet`` when neither is available.
    private func author(_ publicKey: PublicKey?) async throws -> PublicKey {
        if let publicKey { return publicKey }
        return try await client.requiredPublicKey()
    }

    /// Reads a set event authored by the current user, decrypting its private items.
    private func decryptedSet(_ event: Event) async throws -> NostrListSet {
        try await client.withSigner { signer, _ in try await NostrListSet(event: event, decryptingWith: signer) }
    }
}
