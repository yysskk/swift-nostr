import Foundation
import NostrCore

/// NIP-51 lists (one per kind) and sets (many per kind, keyed by a `d` identifier).
/// Reached as ``NostrClient/lists``.
///
/// Private items are NIP-44-encrypted to the author's own key through the configured signer,
/// local or remote. Fetching your own list or set decrypts them; fetching someone else's
/// returns only its public items.
///
/// Implements the ``NostrListManaging`` primitives over the client's signer and relay pool;
/// ``NostrListManaging/fetchSet(naddr:timeout:)`` and the short forms come from the protocol's
/// extension.
public struct NostrListsAPI: NostrListManaging {
    let client: NostrClient

    // MARK: - Lists

    /// Signs and publishes a NIP-51 list, replacing the current list of that kind.
    @discardableResult
    public func publish(_ list: NostrList, strategy: PublishStrategy?) async throws -> PublishedEvent {
        let template = try await client.withSigner { signer, _ in
            try await EventTemplate.list(list, encryptingWith: signer)
        }
        let event = try await client.sign(template)
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches the newest list of `kind`, decrypting private items for the current user's own list
    /// (nil `publicKey`).
    public func fetch(
        kind: Event.Kind,
        for publicKey: PublicKey?,
        timeout: Duration?
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
    @discardableResult
    public func publishSet(
        _ set: NostrListSet,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let template = try await client.withSigner { signer, _ in
            try await EventTemplate.set(set, encryptingWith: signer)
        }
        let event = try await client.sign(template)
        let result = try await client.pool.publish(event, strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches one set by kind and `d` identifier, decrypting private items for the current user's
    /// own set (nil `publicKey`).
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for publicKey: PublicKey?,
        timeout: Duration?
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

    /// Fetches all sets of a kind for an author, newest per `d` identifier, decrypting private items
    /// for the current user's own sets (nil `publicKey`).
    public func fetchSets(
        kind: Event.Kind,
        for publicKey: PublicKey?,
        timeout: Duration?
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
