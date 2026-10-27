import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrEventFetching {
    /// Fetches events matching `filters` from the whole pool, waiting for every relay to send EOSE
    /// or for `timeout`, whichever comes first.
    /// - Parameters:
    ///   - filters: The filters to match.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The events received, deduplicated across relays.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty.
    public func fetch(filters: [Filter], timeout: Duration? = nil) async throws -> [Event] {
        try await fetch(filters: filters, from: nil, timeout: timeout)
    }

    /// Fetches events matching `filters` from the given relays only — for example, `naddr` relay
    /// hints.
    ///
    /// Targets not in the pool are skipped; an empty set always throws.
    /// - Parameters:
    ///   - filters: The filters to match.
    ///   - relayURLs: The relays to fetch from.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The events received, deduplicated across relays.
    /// - Throws: ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool.
    public func fetch(
        filters: [Filter],
        from relayURLs: Set<RelayURL>,
        timeout: Duration? = nil
    ) async throws -> [Event] {
        try await fetch(filters: filters, from: Optional(relayURLs), timeout: timeout)
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT) from the whole pool,
    /// returning the highest count any relay reported.
    /// - Parameters:
    ///   - filters: The filters to count.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The highest count any relay reported.
    /// - Throws: ``RelayPool/Error/emptyPool`` when the pool is empty, or the last relay error when
    ///   no relay answered.
    public func countEvents(matching filters: [Filter], timeout: Duration? = nil) async throws -> Int {
        try await countEvents(matching: filters, from: nil, timeout: timeout)
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT) from the given relays only,
    /// returning the highest count any of them reported.
    ///
    /// Targets not in the pool are skipped; an empty set always throws.
    /// - Parameters:
    ///   - filters: The filters to count.
    ///   - relayURLs: The relays to query.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The highest count any targeted relay reported.
    /// - Throws: ``RelayPool/Error/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool,
    ///   or the last relay error when no targeted relay answered.
    public func countEvents(
        matching filters: [Filter],
        from relayURLs: Set<RelayURL>,
        timeout: Duration? = nil
    ) async throws -> Int {
        try await countEvents(matching: filters, from: Optional(relayURLs), timeout: timeout)
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
        let events = try await fetch(filters: [Filter(ids: [id])], timeout: timeout)
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
    public func fetchMetadata(publicKey: PublicKey, timeout: Duration? = nil) async throws -> UserMetadata? {
        let events = try await fetch(filters: [.metadata(publicKeys: [publicKey])], timeout: timeout)

        guard let event = VerifiedEventSelection.newest(in: events, kind: .setMetadata, author: publicKey)
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
        let events = try await fetch(filters: [filter], timeout: timeout)
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
            events = try await fetch(filters: [filter], timeout: timeout)
        } else {
            do {
                events = try await fetch(filters: [filter], from: Set(naddr.relays), timeout: timeout)
            } catch RelayPool.Error.noMatchingRelays {
                // None of the hints is in the pool. Targeting fails before anything is sent to a
                // relay, so falling back here queries the whole pool exactly once.
                events = try await fetch(filters: [filter], timeout: timeout)
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
