import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrEventFetching {
    /// Fetches events matching `filters` along `route`, waiting for every targeted relay to send
    /// EOSE or for ``RelayPoolConfig/queryTimeout``, whichever comes first. See
    /// ``NostrEventFetching/fetch(filters:route:timeout:)``.
    /// - Parameters:
    ///   - filters: The filters to match.
    ///   - route: The relays to fetch from (default: the whole pool).
    /// - Returns: The events received, deduplicated across relays.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty, or
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of a ``RelayRoute/relays(_:)`` route's URLs
    ///   are in the pool.
    public func fetch(filters: [Filter], route: RelayRoute = .pool) async throws -> [Event] {
        try await fetch(filters: filters, route: route, timeout: nil)
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT) along `route`, waiting up to
    /// ``RelayPoolConfig/queryTimeout`` and returning the highest count any relay reported. See
    /// ``NostrEventFetching/countEvents(matching:route:timeout:)``.
    /// - Parameters:
    ///   - filters: The filters to count.
    ///   - route: The relays to query (default: the whole pool).
    /// - Returns: The highest count any targeted relay reported.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty,
    ///   ``RelayPool/Error/noMatchingRelays(_:)`` when none of a ``RelayRoute/relays(_:)`` route's URLs
    ///   are in the pool, or the last relay error when no targeted relay answered.
    public func countEvents(matching filters: [Filter], route: RelayRoute = .pool) async throws -> Int {
        try await countEvents(matching: filters, route: route, timeout: nil)
    }
}

// MARK: - Conveniences

extension NostrEventFetching {
    /// Fetches a single event by id from the whole pool.
    ///
    /// The returned event is the one that was asked for: a relay that ignores the id filter can
    /// answer with anything, and its signature is checked before it is handed back.
    /// - Parameters:
    ///   - id: The id of the event to fetch.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The event, or nil if no relay returned it with a valid signature.
    public func fetchEvent(id: EventID, timeout: Duration? = nil) async throws -> Event? {
        let events = try await fetch(filters: [Filter(ids: [id])], route: .pool, timeout: timeout)
        return VerifiedEventSelection.event(withID: id, in: events)
    }

    /// Fetches a user's metadata (kind 0) from the whole pool.
    ///
    /// Kind 0 is replaceable, so the newest profile the named public key signed wins; taking
    /// whichever copy arrived first made the result depend on which relay answered soonest.
    /// - Parameters:
    ///   - publicKey: The user whose profile to fetch.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The profile, or nil if none was found or its content does not decode.
    public func fetchMetadata(for publicKey: PublicKey, timeout: Duration? = nil) async throws -> UserMetadata? {
        let events = try await fetch(filters: [.metadata(publicKeys: [publicKey])], route: .pool, timeout: timeout)

        guard let event = VerifiedEventSelection.newest(in: events, kind: .metadata, author: publicKey)
        else { return nil }

        return try? JSONDecoder().decode(UserMetadata.self, from: Data(event.content.utf8))
    }

    /// Fetches a NIP-23 article by author and identifier from the whole pool, keeping the newest
    /// copy across relays.
    /// - Parameters:
    ///   - author: The article's author.
    ///   - identifier: The article's `d` identifier.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(
        author: PublicKey,
        identifier: String,
        timeout: Duration? = nil
    ) async throws -> LongFormContent? {
        var filter = Filter(authors: [author], kinds: [.longFormContent])
        filter[tag: .identifier] = [identifier]
        let events = try await fetch(filters: [filter], route: .pool, timeout: timeout)
        // Addressable event: the newest copy the named author signed under this identifier.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events, kind: .longFormContent, author: author, identifier: identifier)
        else {
            return nil
        }
        return LongFormContent(event: newest)
    }

    /// Fetches the NIP-23 article addressed by an `naddr` coordinate.
    ///
    /// The coordinate's relay hints are queried when any of them is in the pool — hints not in the
    /// pool are skipped, not connected on demand; otherwise, or when it carries none, the whole
    /// pool is queried.
    /// - Parameters:
    ///   - naddr: The article's coordinate.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The article, or nil if none was found.
    public func fetchLongFormContent(naddr: NAddr, timeout: Duration? = nil) async throws -> LongFormContent? {
        var filter = Filter(authors: [naddr.author], kinds: [naddr.kind])
        filter[tag: .identifier] = [naddr.identifier]

        let events: [Event]
        if naddr.relays.isEmpty {
            events = try await fetch(filters: [filter], route: .pool, timeout: timeout)
        } else {
            do {
                events = try await fetch(filters: [filter], route: .relays(Set(naddr.relays)), timeout: timeout)
            } catch RelayPool.Error.noMatchingRelays {
                // None of the hints is in the pool. Targeting fails before anything is sent to a
                // relay, so falling back here queries the whole pool exactly once.
                events = try await fetch(filters: [filter], route: .pool, timeout: timeout)
            }
        }

        // Addressable event: the coordinate names the author, kind, and identifier, so all three
        // are checked — a relay hint the coordinate carries is not a reason to trust what it sends.
        guard
            let newest = VerifiedEventSelection.newest(
                in: events,
                kind: naddr.kind,
                author: naddr.author,
                identifier: naddr.identifier)
        else {
            return nil
        }
        return LongFormContent(event: newest)
    }
}
