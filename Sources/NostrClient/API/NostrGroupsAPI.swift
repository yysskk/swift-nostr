import Foundation
import NostrCore

/// NIP-29 relay-based groups, plus the NIP-51 kind-10009 list that records which groups a user
/// is in. Reached as ``NostrClient/groups``.
///
/// A NIP-29 group lives on a single relay, so every flow here targets exactly that relay, adding
/// and connecting it on demand. Private groups require NIP-42 AUTH before the relay serves or
/// accepts their events; the client's automatic responder answers challenges when a signer is set.
///
/// Implements the ``NostrGroupManaging`` primitives over the client's signer, relay pool, and
/// ``NostrClient/lists``; ``NostrGroupManaging/join(_:inviteCode:reason:strategy:)``,
/// ``NostrGroupManaging/leave(_:reason:strategy:)``,
/// ``NostrGroupManaging/publishMessage(_:kind:in:tags:previous:strategy:)``, and
/// ``NostrGroupManaging/publishModeration(_:in:previous:reason:strategy:)`` build their NIP-29
/// templates in the protocol's extension and publish them through ``publish(_:in:strategy:)``.
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct NostrGroupsAPI: NostrGroupManaging {
    let client: NostrClient

    // MARK: - Publishing

    /// Signs `template` with the configured signer and publishes it to the group's relay only,
    /// adding and connecting the relay on demand.
    ///
    /// Signing comes first, so without a signer ``NostrClient/Error/signerNotSet`` is thrown before the
    /// group's relay is touched.
    @discardableResult
    public func publish(
        _ template: EventTemplate,
        in group: GroupReference,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        let event = try await client.sign(template)
        let relayURL = try await ensureRelay(group)
        let result = try await client.pool.publish(event, to: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    // MARK: - Reading

    /// Fetches the group's kind-39000 metadata from its relay, newest-wins across stale copies,
    /// validated against `authorPublicKey ?? group.relayPublicKey` when either is set.
    public func fetchMetadata(
        for group: GroupReference,
        authorPublicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> Groups.Metadata? {
        let relayURL = try await ensureRelay(group)
        let author = authorPublicKey ?? group.relayPublicKey
        let events = try await client.fetch(
            filters: [.groupState(groupID: group.id, kinds: [.groupMetadata])],
            fromURLs: [relayURL],
            timeout: timeout
        )
        guard let newest = Self.newestStateEvent(ofKind: .groupMetadata, in: events, author: author) else {
            return nil
        }
        return try Groups.Metadata(event: newest, relayPublicKey: author)
    }

    /// Fetches the group's full relay-generated state snapshot from its relay in one round trip,
    /// newest per kind, with the same author validation as
    /// ``fetchMetadata(for:authorPublicKey:timeout:)``.
    public func fetchState(
        for group: GroupReference,
        authorPublicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> GroupState {
        let relayURL = try await ensureRelay(group)
        let author = authorPublicKey ?? group.relayPublicKey
        let events = try await client.fetch(
            filters: [.groupState(groupID: group.id)],
            fromURLs: [relayURL],
            timeout: timeout
        )

        var state = GroupState()
        if let event = Self.newestStateEvent(ofKind: .groupMetadata, in: events, author: author) {
            state.metadata = try Groups.Metadata(event: event, relayPublicKey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupAdmins, in: events, author: author) {
            state.admins = try Groups.AdminList(event: event, relayPublicKey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupMembers, in: events, author: author) {
            state.members = try Groups.MemberList(event: event, relayPublicKey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupRoles, in: events, author: author) {
            state.roles = try Groups.RoleList(event: event, relayPublicKey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupPinList, in: events, author: author) {
            state.pins = try Groups.PinList(event: event, relayPublicKey: author)
        }
        return state
    }

    /// Subscribes to the group's live content matching `filters`, each scoped to the group by its
    /// "h" tag, from its relay only.
    public func subscribe(to group: GroupReference, filters: [Filter]) async throws -> SubscriptionSequence {
        let relayURL = try await ensureRelay(group)
        let scoped = filters.map { filter in
            var filter = filter
            filter[tag: .group] = [group.id]
            return filter
        }
        return try await client.pool.subscribe(filters: scoped, to: [relayURL])
    }

    // MARK: - Membership list (NIP-51 kind 10009)

    /// Fetches the newest kind-10009 simple group list — a thin typed wrapper over
    /// ``NostrListsAPI/fetch(kind:for:timeout:)`` with the same decryption and throwing behavior.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    public func fetchSimpleGroupList(
        for publicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> SimpleGroupList? {
        guard let list = try await client.lists.fetch(kind: .simpleGroupList, for: publicKey, timeout: timeout) else {
            return nil
        }
        return try SimpleGroupList(list: list)
    }

    /// Signs and publishes the list (kind 10009) to the whole pool, replacing the user's current
    /// simple group list — a wrapper over ``NostrListsAPI/publish(_:strategy:)``.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/51.md
    @discardableResult
    public func publishSimpleGroupList(
        _ list: SimpleGroupList,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        try await client.lists.publish(list.list, strategy: strategy)
    }

    // MARK: - Private

    /// Ensures the group's relay is in the pool and connected, returning its routing URL.
    ///
    /// A NIP-29 group lives on a single relay, so every group flow targets exactly that
    /// relay; targeting a URL the pool does not know throws
    /// ``RelayPool/Error/noMatchingRelays(_:)``, so this helper guarantees the relay is
    /// present and connected first. The relay is added when absent, and connecting is
    /// idempotent when it already is connected.
    ///
    /// - Returns: The group's relay URL, to pass to the pool's targeting parameters.
    /// - Throws: ``RelayConnection/Error`` when the relay cannot be connected.
    private func ensureRelay(_ group: GroupReference) async throws(RelayConnection.Error) -> RelayURL {
        let connection = await client.pool.addRelay(group.relayURL)
        try await connection.connect()
        return group.relayURL
    }

    /// Picks the winning event of one relay-generated state kind: the newest `createdAt`,
    /// with ties broken by the lowest event id (the NIP-01 replaceable-event convention).
    ///
    /// With an expected `author`, this is the same selection every other replaceable fetch makes,
    /// so it goes through ``VerifiedEventSelection``. Without one — a group whose relay has not
    /// been identified yet — nothing can be verified against, so the newest of what arrived is
    /// taken as-is.
    private static func newestStateEvent(ofKind kind: Event.Kind, in events: [Event], author: PublicKey?) -> Event? {
        guard author == nil else {
            return VerifiedEventSelection.newest(in: events, kind: kind, author: author)
        }

        var newest: Event?
        for event in events where event.kind == kind {
            if let current = newest {
                let supersedes =
                    event.createdAt > current.createdAt
                    || (event.createdAt == current.createdAt && event.id < current.id)
                guard supersedes else { continue }
            }
            newest = event
        }
        return newest
    }
}
