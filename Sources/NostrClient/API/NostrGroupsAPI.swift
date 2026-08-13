import Foundation
import NostrCore

/// NIP-29 relay-based groups, plus the NIP-51 kind-10009 list that records which groups a user
/// is in. Reached as ``NostrClient/groups``.
///
/// A NIP-29 group lives on a single relay, so every flow here targets exactly that relay, adding
/// and connecting it on demand. Private groups require NIP-42 AUTH before the relay serves or
/// accepts their events; the client's automatic responder answers challenges when a signer is set.
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct NostrGroupsAPI: NostrGroupManaging {
    let client: NostrClient

    // MARK: - Membership

    /// Requests to join a group (kind 9021), publishing only to the group's relay.
    ///
    /// The invite code applied is `inviteCode ?? group.inviteCode`, so a reference parsed
    /// from a share link with a "?invite=<code>" suffix works unchanged. Closed groups
    /// accept the request automatically for a valid code; otherwise an admin decides, and
    /// the relay reports an already-member state with a "duplicate:" OK message.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too.
    ///
    /// - Parameters:
    ///   - group: The group to join; its relay is added to the pool and connected on demand.
    ///   - inviteCode: An invite code overriding `group.inviteCode`, if any.
    ///   - reason: An optional free-form message to the group's admins (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: ``NostrError/signerNotSet`` without a signer, plus anything the signer,
    ///   connection, or publish throws.
    @discardableResult
    public func join(
        _ group: GroupReference,
        inviteCode: String? = nil,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(to: group, strategy: strategy) { pubkey in
            Groups.joinRequest(
                groupID: group.id,
                inviteCode: inviteCode ?? group.inviteCode,
                reason: reason,
                pubkey: pubkey
            )
        }
    }

    /// Requests to leave a group (kind 9022), publishing only to the group's relay; the
    /// relay answers by issuing a kind-9001 removal for the author.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too.
    ///
    /// - Parameters:
    ///   - group: The group to leave; its relay is added to the pool and connected on demand.
    ///   - reason: An optional free-form message (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: ``NostrError/signerNotSet`` without a signer, plus anything the signer,
    ///   connection, or publish throws.
    @discardableResult
    public func leave(
        _ group: GroupReference,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(to: group, strategy: strategy) { pubkey in
            Groups.leaveRequest(groupID: group.id, reason: reason, pubkey: pubkey)
        }
    }

    // MARK: - Posting

    /// Publishes a content event into a group, only to the group's relay.
    ///
    /// NIP-29 defines no content kinds of its own; the default kind is the NIP-C7 chat
    /// message (kind 9). The event's first tag is the group's "h" tag, followed by `tags`,
    /// then a "previous" tag when `previous` is non-empty. Timeline references stay a
    /// caller-supplied parameter — sample them from recently seen group events with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``; nothing is fetched
    /// behind your back.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too.
    ///
    /// - Parameters:
    ///   - content: The event content.
    ///   - kind: The content kind (default: ``Event/Kind/chatMessage``).
    ///   - group: The group to post into; its relay is added to the pool and connected on demand.
    ///   - tags: Additional tags, appended after the "h" tag in order.
    ///   - previous: Timeline references for a trailing "previous" tag. Omitted when empty.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: ``NostrError/signerNotSet`` without a signer, plus anything the signer,
    ///   connection, or publish throws.
    @discardableResult
    public func publishMessage(
        _ content: String,
        kind: Event.Kind = .chatMessage,
        in group: GroupReference,
        tags: [Tag] = [],
        previous: [String] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(to: group, strategy: strategy) { pubkey in
            Groups.contentEvent(
                groupID: group.id,
                kind: kind,
                content: content,
                tags: tags,
                previous: previous,
                pubkey: pubkey
            )
        }
    }

    /// Publishes a moderation action (kinds 9000-9002, 9005, 9007-9010), only to the group's relay,
    /// which enforces the author's role permissions and answers with an OK message.
    ///
    /// See ``Groups/ModerationAction`` for the actions and their tag layouts. Timeline
    /// references stay a caller-supplied parameter — sample them with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too.
    ///
    /// - Parameters:
    ///   - action: The moderation action to request.
    ///   - group: The group to moderate; its relay is added to the pool and connected on demand.
    ///   - previous: Timeline references for a trailing "previous" tag. Omitted when empty.
    ///   - reason: An optional human-readable reason (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: ``NostrError/signerNotSet`` without a signer, plus anything the signer,
    ///   connection, or publish throws.
    @discardableResult
    public func publishModeration(
        _ action: Groups.ModerationAction,
        in group: GroupReference,
        previous: [String] = [],
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(to: group, strategy: strategy) { pubkey in
            Groups.moderationEvent(action, groupID: group.id, previous: previous, reason: reason, pubkey: pubkey)
        }
    }

    // MARK: - Reading

    /// Fetches the group's kind-39000 metadata from its relay, newest-wins across stale copies.
    ///
    /// When `authorPubkey ?? group.relayPubkey` is non-nil, candidate events are verified
    /// (``Event/verify()``) and events by any other author are dropped before the
    /// newest-wins pick, and the parser applies the same author check; when nil, the newest
    /// event is parsed as-is — the relay you are already trusting as transport is the
    /// authority on its own groups.
    ///
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPubkey: The relay pubkey to validate against, overriding `group.relayPubkey`.
    ///   - timeout: How long to wait for the relay's EOSE (default: 10 seconds).
    /// - Returns: The parsed metadata, or nil when the relay returned no usable event.
    /// - Throws: ``Groups/ValidationError`` when the winning event does not parse, plus
    ///   anything the connection or fetch throws.
    public func fetchMetadata(
        for group: GroupReference,
        authorPubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Groups.Metadata? {
        let relayURL = try await ensureRelay(group)
        let author = authorPubkey ?? group.relayPubkey
        let events = try await client.fetch(
            filters: [.groupState(groupID: group.id, kinds: [.groupMetadata])],
            toURLs: [relayURL],
            timeout: timeout
        )
        guard let newest = Self.newestStateEvent(ofKind: .groupMetadata, in: events, author: author) else {
            return nil
        }
        return try Groups.Metadata(event: newest, relayPubkey: author)
    }

    /// Fetches the group's full relay-generated state snapshot — metadata, admins, members,
    /// roles, and pins — from its relay in one round trip (``Filter/groupState(groupID:kinds:)``).
    ///
    /// The newest event per kind wins, with the same author-validation semantics as
    /// ``fetchMetadata(for:authorPubkey:timeout:)``. Fields stay nil when the relay
    /// published nothing for that kind — for example the member list of a private group.
    ///
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPubkey: The relay pubkey to validate against, overriding `group.relayPubkey`.
    ///   - timeout: How long to wait for the relay's EOSE (default: 10 seconds).
    /// - Returns: The snapshot, with a nil field per kind the relay did not answer for.
    /// - Throws: ``Groups/ValidationError`` when a winning event does not parse, plus
    ///   anything the connection or fetch throws.
    public func fetchState(
        for group: GroupReference,
        authorPubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> GroupState {
        let relayURL = try await ensureRelay(group)
        let author = authorPubkey ?? group.relayPubkey
        let events = try await client.fetch(
            filters: [.groupState(groupID: group.id)],
            toURLs: [relayURL],
            timeout: timeout
        )

        var state = GroupState()
        if let event = Self.newestStateEvent(ofKind: .groupMetadata, in: events, author: author) {
            state.metadata = try Groups.Metadata(event: event, relayPubkey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupAdmins, in: events, author: author) {
            state.admins = try Groups.AdminList(event: event, relayPubkey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupMembers, in: events, author: author) {
            state.members = try Groups.MemberList(event: event, relayPubkey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupRoles, in: events, author: author) {
            state.roles = try Groups.RoleList(event: event, relayPubkey: author)
        }
        if let event = Self.newestStateEvent(ofKind: .groupPinList, in: events, author: author) {
            state.pins = try Groups.PinList(event: event, relayPubkey: author)
        }
        return state
    }

    /// Subscribes to the live timeline of the group's content — events carrying its "h"
    /// tag — from its relay only.
    ///
    /// Iteration termination automatically sends CLOSE, like every subscription from
    /// ``NostrSubscriptionsAPI/subscribe(filters:to:bufferingPolicy:)``.
    ///
    /// - Parameters:
    ///   - group: The group to follow; its relay is added to the pool and connected on demand.
    ///   - kinds: The content kinds to receive; nil (the default) receives all kinds.
    ///   - since: Only events created at or after this moment, if given.
    ///   - limit: The maximum number of stored events the relay should send, if given.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    /// - Throws: Anything the connection or subscribe throws.
    public func timeline(
        _ group: GroupReference,
        kinds: [Event.Kind]? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        let relayURL = try await ensureRelay(group)
        let filter = Filter.groupTimeline(
            groupID: group.id,
            kinds: kinds,
            since: since.map { Int64($0.timeIntervalSince1970) },
            limit: limit
        )
        return try await client.subscribe(filters: [filter], toURLs: [relayURL])
    }

    // MARK: - Membership list (NIP-51 kind 10009)

    /// Fetches the newest kind-10009 simple group list — the NIP-29 groups a user is in.
    ///
    /// With no `pubkey` it fetches the current user's list and decrypts private entries;
    /// for another pubkey only public entries are returned. A thin typed wrapper over
    /// ``NostrListsAPI/fetch(kind:for:timeout:)`` with the same throwing behavior: fetching the
    /// current user's own list throws when the list's private content cannot be decrypted
    /// (republishing such a list would silently drop the private entries).
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
        guard let list = try await client.lists.fetch(kind: .simpleGroupList, for: pubkey, timeout: timeout) else {
            return nil
        }
        return try SimpleGroupList(list: list)
    }

    /// Signs and publishes the list (kind 10009), replacing the user's current simple
    /// group list.
    ///
    /// Unlike the group flows, which target a group's single relay, this broadcasts to
    /// the whole pool — a replaceable list lives everywhere, so every relay carrying the
    /// user's events receives the fresh copy. Wraps ``NostrListsAPI/publish(_:strategy:)``:
    /// private entries are NIP-44-encrypted to the user's own key through the configured signer,
    /// local or remote (with no signer, ``NostrError/signerNotSet``).
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
        try await client.lists.publish(list.list, strategy: strategy)
    }

    // MARK: - Private

    /// Signs an event built for the group and publishes it to the group's relay only —
    /// the shape every write flow above shares.
    private func publish(
        to group: GroupReference,
        strategy: PublishStrategy?,
        _ build: (_ publicKey: String) -> UnsignedEvent
    ) async throws -> PublishedEvent {
        let pubkey = try await client.requiredPublicKey()
        let relayURL = try await ensureRelay(group)
        let event = try await client.activeSign(build(pubkey))
        let result = try await client.pool.publish(event, toURLs: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Ensures the group's relay is in the pool and connected, returning its routing URL.
    ///
    /// A NIP-29 group lives on a single relay, so every group flow targets exactly that
    /// relay; targeting a URL the pool does not know throws
    /// ``NostrError/noMatchingRelays(_:)``, so this helper guarantees the relay is
    /// present and connected first. The URL is normalized like every other routing key
    /// (lowercased scheme and host, root trailing slash stripped, default ports
    /// stripped), the relay is added when absent, and connecting is idempotent when it
    /// already is connected.
    ///
    /// - Returns: The normalized URL to pass to the pool's targeting parameters.
    /// - Throws: ``NostrError/invalidRelayURL(_:)`` when the URL is not a valid WebSocket
    ///   relay URL, or ``NostrError/connectionFailed(_:)`` when the relay cannot be connected.
    private func ensureRelay(_ group: GroupReference) async throws -> URL {
        let url = try RelayURL.requireTarget(group.relayURL)
        let connection = try await client.pool.addRelay(url)
        try await connection.connect()
        return url
    }

    /// Picks the winning event of one relay-generated state kind: the newest `createdAt`,
    /// with ties broken by the lowest event id (the NIP-01 replaceable-event convention).
    ///
    /// With an expected `author`, this is the same selection every other replaceable fetch makes,
    /// so it goes through ``VerifiedEventSelection``. Without one — a group whose relay has not
    /// been identified yet — nothing can be verified against, so the newest of what arrived is
    /// taken as-is.
    private static func newestStateEvent(ofKind kind: Event.Kind, in events: [Event], author: String?) -> Event? {
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
