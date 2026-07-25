import Foundation
import NostrCore

// MARK: - Relay-based Groups (NIP-29)
extension NostrClient {
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
    func ensureGroupRelay(_ group: GroupReference) async throws -> URL {
        let url = try RelayURL.requireTarget(group.relayURL)
        let connection = try await relayPool.addRelay(url)
        try await connection.connect()
        return url
    }

    /// Requests to join a group (kind 9021), publishing only to the group's relay.
    ///
    /// The invite code applied is `inviteCode ?? group.inviteCode`, so a reference parsed
    /// from a share link with a "?invite=<code>" suffix works unchanged. Closed groups
    /// accept the request automatically for a valid code; otherwise an admin decides, and
    /// the relay reports an already-member state with a "duplicate:" OK message.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too. Private
    /// groups require NIP-42 AUTH, which the client's automatic responder answers when a
    /// signer is set (see ``AuthenticationMode/automatic``).
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
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
    public func joinGroup(
        _ group: GroupReference,
        inviteCode: String? = nil,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let pubkey = publicKey else { throw NostrError.signerNotSet }
        let relayURL = try await ensureGroupRelay(group)
        let event = try await activeSign(
            Groups.joinRequest(
                groupID: group.id,
                inviteCode: inviteCode ?? group.inviteCode,
                reason: reason,
                pubkey: pubkey
            )
        )
        let result = try await relayPool.publish(event, toURLs: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Requests to leave a group (kind 9022), publishing only to the group's relay; the
    /// relay answers by issuing a kind-9001 removal for the author.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too. Private
    /// groups require NIP-42 AUTH, which the client's automatic responder answers when a
    /// signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
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
    public func leaveGroup(
        _ group: GroupReference,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let pubkey = publicKey else { throw NostrError.signerNotSet }
        let relayURL = try await ensureGroupRelay(group)
        let event = try await activeSign(
            Groups.leaveRequest(groupID: group.id, reason: reason, pubkey: pubkey)
        )
        let result = try await relayPool.publish(event, toURLs: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a content event into a group, only to the group's relay.
    ///
    /// NIP-29 defines no content kinds of its own; the default kind is the NIP-C7 chat
    /// message (kind 9). The event's first tag is the group's "h" tag, followed by `tags`,
    /// then a "previous" tag when `previous` is non-empty. Timeline references stay a
    /// caller-supplied parameter — sample them from recently seen group events with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``; nothing is fetched
    /// behind your back.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too. Private
    /// groups require NIP-42 AUTH, which the client's automatic responder answers when a
    /// signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
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
    public func publishGroupMessage(
        _ content: String,
        kind: Event.Kind = .chatMessage,
        in group: GroupReference,
        tags: [Tag] = [],
        previous: [String] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let pubkey = publicKey else { throw NostrError.signerNotSet }
        let relayURL = try await ensureGroupRelay(group)
        let event = try await activeSign(
            Groups.contentEvent(
                groupID: group.id,
                kind: kind,
                content: content,
                tags: tags,
                previous: previous,
                pubkey: pubkey
            )
        )
        let result = try await relayPool.publish(event, toURLs: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Publishes a moderation action (kinds 9000-9002, 9005, 9007-9010), only to the group's relay, which
    /// enforces the author's role permissions and answers with an OK message.
    ///
    /// See ``Groups/ModerationAction`` for the actions and their tag layouts. Timeline
    /// references stay a caller-supplied parameter — sample them with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``.
    ///
    /// Signing goes through the active signer, so a remote NIP-46 signer works too. Private
    /// groups require NIP-42 AUTH, which the client's automatic responder answers when a
    /// signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
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
    public func publishGroupModeration(
        _ action: Groups.ModerationAction,
        in group: GroupReference,
        previous: [String] = [],
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        guard let pubkey = publicKey else { throw NostrError.signerNotSet }
        let relayURL = try await ensureGroupRelay(group)
        let event = try await activeSign(
            Groups.moderationEvent(action, groupID: group.id, previous: previous, reason: reason, pubkey: pubkey)
        )
        let result = try await relayPool.publish(event, toURLs: [relayURL], strategy: strategy)
        return PublishedEvent(event: event, result: result)
    }

    /// Fetches the group's kind-39000 metadata from its relay, newest-wins across stale copies.
    ///
    /// When `authorPubkey ?? group.relayPubkey` is non-nil, candidate events are verified
    /// (``Event/verify()``) and events by any other author are dropped before the
    /// newest-wins pick, and the parser applies the same author check; when nil, the newest
    /// event is parsed as-is — the relay you are already trusting as transport is the
    /// authority on its own groups.
    ///
    /// Private and hidden groups may require NIP-42 AUTH before the relay serves their
    /// state; the client's automatic responder answers challenges when a signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    ///
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPubkey: The relay pubkey to validate against, overriding `group.relayPubkey`.
    ///   - timeout: How long to wait for the relay's EOSE (default: 10 seconds).
    /// - Returns: The parsed metadata, or nil when the relay returned no usable event.
    /// - Throws: ``Groups/ValidationError`` when the winning event does not parse, plus
    ///   anything the connection or fetch throws.
    public func fetchGroupMetadata(
        for group: GroupReference,
        authorPubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Groups.Metadata? {
        let relayURL = try await ensureGroupRelay(group)
        let author = authorPubkey ?? group.relayPubkey
        let events = try await fetch(
            filters: [.groupState(groupID: group.id, kinds: [.groupMetadata])],
            toURLs: [relayURL],
            timeout: timeout
        )
        guard let newest = Self.newestGroupStateEvent(ofKind: .groupMetadata, in: events, author: author) else {
            return nil
        }
        return try Groups.Metadata(event: newest, relayPubkey: author)
    }

    /// Fetches the group's full relay-generated state snapshot — metadata, admins, members,
    /// roles, and pins — from its relay in one round trip (``Filter/groupState(groupID:kinds:)``).
    ///
    /// The newest event per kind wins, with the same author-validation semantics as
    /// ``fetchGroupMetadata(for:authorPubkey:timeout:)``. Fields stay nil when the relay
    /// published nothing for that kind — for example the member list of a private group.
    ///
    /// Private and hidden groups may require NIP-42 AUTH before the relay serves their
    /// state; the client's automatic responder answers challenges when a signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    ///
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPubkey: The relay pubkey to validate against, overriding `group.relayPubkey`.
    ///   - timeout: How long to wait for the relay's EOSE (default: 10 seconds).
    /// - Returns: The snapshot, with a nil field per kind the relay did not answer for.
    /// - Throws: ``Groups/ValidationError`` when a winning event does not parse, plus
    ///   anything the connection or fetch throws.
    public func fetchGroupState(
        for group: GroupReference,
        authorPubkey: String? = nil,
        timeout: TimeInterval = 10
    ) async throws -> GroupState {
        let relayURL = try await ensureGroupRelay(group)
        let author = authorPubkey ?? group.relayPubkey
        let events = try await fetch(
            filters: [.groupState(groupID: group.id)],
            toURLs: [relayURL],
            timeout: timeout
        )

        var state = GroupState()
        if let event = Self.newestGroupStateEvent(ofKind: .groupMetadata, in: events, author: author) {
            state.metadata = try Groups.Metadata(event: event, relayPubkey: author)
        }
        if let event = Self.newestGroupStateEvent(ofKind: .groupAdmins, in: events, author: author) {
            state.admins = try Groups.AdminList(event: event, relayPubkey: author)
        }
        if let event = Self.newestGroupStateEvent(ofKind: .groupMembers, in: events, author: author) {
            state.members = try Groups.MemberList(event: event, relayPubkey: author)
        }
        if let event = Self.newestGroupStateEvent(ofKind: .groupRoles, in: events, author: author) {
            state.roles = try Groups.RoleList(event: event, relayPubkey: author)
        }
        if let event = Self.newestGroupStateEvent(ofKind: .groupPinList, in: events, author: author) {
            state.pins = try Groups.PinList(event: event, relayPubkey: author)
        }
        return state
    }

    /// Subscribes to the live timeline of the group's content — events carrying its "h"
    /// tag — from its relay only.
    ///
    /// Iteration termination automatically sends CLOSE, like every subscription from
    /// ``subscribe(filters:to:bufferingPolicy:)``. Private groups require NIP-42 AUTH
    /// before the relay serves their events; the client's automatic responder answers
    /// challenges when a signer is set.
    ///
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    ///
    /// - Parameters:
    ///   - group: The group to follow; its relay is added to the pool and connected on demand.
    ///   - kinds: The content kinds to receive; nil (the default) receives all kinds.
    ///   - since: Only events created at or after this moment, if given.
    ///   - limit: The maximum number of stored events the relay should send, if given.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    /// - Throws: Anything the connection or subscribe throws.
    public func subscribeToGroupTimeline(
        _ group: GroupReference,
        kinds: [Event.Kind]? = nil,
        since: Date? = nil,
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        let relayURL = try await ensureGroupRelay(group)
        let filter = Filter.groupTimeline(
            groupID: group.id,
            kinds: kinds,
            since: since.map { Int64($0.timeIntervalSince1970) },
            limit: limit
        )
        return try await subscribe(filters: [filter], toURLs: [relayURL])
    }

    /// Picks the winning event of one relay-generated state kind: the newest `createdAt`,
    /// with ties broken by the lowest event id (the NIP-01 replaceable-event convention).
    /// With an expected `author`, events by anyone else and events whose signature does not
    /// verify are dropped before the pick.
    private static func newestGroupStateEvent(ofKind kind: Event.Kind, in events: [Event], author: String?) -> Event? {
        var newest: Event?
        for event in events where event.kind == kind {
            if let author {
                guard event.pubkey == author, (try? event.verify()) == true else { continue }
            }
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
