import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrListManaging {
    /// Signs and publishes a NIP-51 list to the whole pool, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See ``NostrListManaging/publish(_:strategy:)``.
    /// - Parameter list: The list to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publish(_ list: NostrList) async throws -> PublishedEvent {
        try await publish(list, strategy: nil)
    }

    /// Fetches the current user's newest list of `kind`, decrypting its private items. See
    /// ``NostrListManaging/fetch(kind:for:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The list kind.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The list, or nil if none was found.
    public func fetch(kind: Event.Kind, timeout: Duration? = nil) async throws -> NostrList? {
        try await fetch(kind: kind, for: nil, timeout: timeout)
    }

    /// Fetches another user's newest list of `kind`, with only its public items. See
    /// ``NostrListManaging/fetch(kind:for:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The list kind.
    ///   - publicKey: The list's author.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The list, or nil if none was found.
    public func fetch(kind: Event.Kind, for publicKey: PublicKey, timeout: Duration? = nil) async throws -> NostrList? {
        try await fetch(kind: kind, for: Optional(publicKey), timeout: timeout)
    }

    /// Signs and publishes a NIP-51 set to the whole pool, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See ``NostrListManaging/publishSet(_:strategy:)``.
    /// - Parameter set: The set to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSet(_ set: NostrListSet) async throws -> PublishedEvent {
        try await publishSet(set, strategy: nil)
    }

    /// Fetches one of the current user's sets by kind and `d` identifier, decrypting its private
    /// items. See ``NostrListManaging/fetchSet(kind:identifier:for:timeout:)-(_,_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - identifier: The set's `d` identifier.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        timeout: Duration? = nil
    ) async throws -> NostrListSet? {
        try await fetchSet(kind: kind, identifier: identifier, for: nil, timeout: timeout)
    }

    /// Fetches one of another user's sets by kind and `d` identifier, with only its public items.
    /// See ``NostrListManaging/fetchSet(kind:identifier:for:timeout:)-(_,_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - identifier: The set's `d` identifier.
    ///   - publicKey: The set's author.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for publicKey: PublicKey,
        timeout: Duration? = nil
    ) async throws -> NostrListSet? {
        try await fetchSet(kind: kind, identifier: identifier, for: Optional(publicKey), timeout: timeout)
    }

    /// Fetches every one of the current user's sets of a kind, newest per `d` identifier, decrypting
    /// their private items. See ``NostrListManaging/fetchSets(kind:for:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The sets, in no guaranteed order.
    public func fetchSets(kind: Event.Kind, timeout: Duration? = nil) async throws -> [NostrListSet] {
        try await fetchSets(kind: kind, for: nil, timeout: timeout)
    }

    /// Fetches every one of another user's sets of a kind, newest per `d` identifier, with only
    /// their public items. See ``NostrListManaging/fetchSets(kind:for:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - publicKey: The sets' author.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The sets, in no guaranteed order.
    public func fetchSets(
        kind: Event.Kind,
        for publicKey: PublicKey,
        timeout: Duration? = nil
    ) async throws -> [NostrListSet] {
        try await fetchSets(kind: kind, for: Optional(publicKey), timeout: timeout)
    }
}

// MARK: - Conveniences

extension NostrListManaging {
    /// Fetches the set addressed by a NIP-19 `naddr` from the whole pool, with only its public items.
    ///
    /// The coordinate's author is passed explicitly, so private items are never decrypted — even
    /// for the current user's own set; fetch it with
    /// ``NostrListManaging/fetchSet(kind:identifier:timeout:)`` for those. The coordinate's relay
    /// hints are not used.
    /// - Parameters:
    ///   - naddr: The set's coordinate.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(naddr: NAddr, timeout: Duration? = nil) async throws -> NostrListSet? {
        try await fetchSet(
            kind: naddr.kind,
            identifier: naddr.identifier,
            for: Optional(naddr.author),
            timeout: timeout
        )
    }
}
