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

    /// Fetches a user's newest list of `kind`, waiting up to the pool config's
    /// ``RelayPoolConfig/queryTimeout``. See ``NostrListManaging/fetch(kind:for:timeout:)``.
    /// - Parameters:
    ///   - kind: The list kind.
    ///   - publicKey: The list's author (default: nil, for the current user, whose private items are
    ///     decrypted).
    /// - Returns: The list, or nil if none was found.
    public func fetch(kind: Event.Kind, for publicKey: PublicKey? = nil) async throws -> NostrList? {
        try await fetch(kind: kind, for: publicKey, timeout: nil)
    }

    /// Signs and publishes a NIP-51 set to the whole pool, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See ``NostrListManaging/publishSet(_:strategy:)``.
    /// - Parameter set: The set to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSet(_ set: NostrListSet) async throws -> PublishedEvent {
        try await publishSet(set, strategy: nil)
    }

    /// Fetches one of a user's sets by kind and `d` identifier, waiting up to the pool config's
    /// ``RelayPoolConfig/queryTimeout``. See ``NostrListManaging/fetchSet(kind:identifier:for:timeout:)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - identifier: The set's `d` identifier.
    ///   - publicKey: The set's author (default: nil, for the current user, whose private items are
    ///     decrypted).
    /// - Returns: The set, or nil if none was found.
    public func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for publicKey: PublicKey? = nil
    ) async throws -> NostrListSet? {
        try await fetchSet(kind: kind, identifier: identifier, for: publicKey, timeout: nil)
    }

    /// Fetches every one of a user's sets of a kind, newest per `d` identifier, waiting up to the
    /// pool config's ``RelayPoolConfig/queryTimeout``. See ``NostrListManaging/fetchSets(kind:for:timeout:)``.
    /// - Parameters:
    ///   - kind: The set kind.
    ///   - publicKey: The sets' author (default: nil, for the current user, whose private items are
    ///     decrypted).
    /// - Returns: The sets, in no guaranteed order.
    public func fetchSets(kind: Event.Kind, for publicKey: PublicKey? = nil) async throws -> [NostrListSet] {
        try await fetchSets(kind: kind, for: publicKey, timeout: nil)
    }
}

// MARK: - Conveniences

extension NostrListManaging {
    /// Fetches the set addressed by a NIP-19 `naddr` from the whole pool, with only its public items.
    ///
    /// The coordinate's author is passed explicitly, so private items are never decrypted — even
    /// for the current user's own set; fetch it with
    /// ``NostrListManaging/fetchSet(kind:identifier:for:)`` for those. The coordinate's relay
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
            for: naddr.author,
            timeout: timeout
        )
    }
}
