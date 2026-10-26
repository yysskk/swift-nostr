import Foundation
import NostrCore

// MARK: - Short forms of the primitives

extension NostrGroupManaging {
    /// Signs `template` and publishes it only to the group's relay, waiting for the pool config's
    /// ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrGroupManaging/publish(_:in:strategy:)``.
    /// - Parameters:
    ///   - template: The event to sign and publish.
    ///   - group: The group whose relay receives the event.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publish(_ template: EventTemplate, in group: GroupReference) async throws -> PublishedEvent {
        try await publish(template, in: group, strategy: nil)
    }

    /// Fetches the group's kind-39000 metadata from its relay, validated against
    /// `group.relayPublicKey` when the reference carries one. See
    /// ``NostrGroupManaging/fetchMetadata(for:authorPublicKey:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - timeout: How long to wait for the relay to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The parsed metadata, or nil when the relay returned no usable event.
    public func fetchMetadata(for group: GroupReference, timeout: Duration? = nil) async throws -> Groups.Metadata? {
        try await fetchMetadata(for: group, authorPublicKey: nil, timeout: timeout)
    }

    /// Fetches the group's kind-39000 metadata from its relay, validated against `authorPublicKey`.
    /// See ``NostrGroupManaging/fetchMetadata(for:authorPublicKey:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPublicKey: The relay public key to validate against, overriding
    ///     `group.relayPublicKey`.
    ///   - timeout: How long to wait for the relay to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The parsed metadata, or nil when the relay returned no usable event.
    public func fetchMetadata(
        for group: GroupReference,
        authorPublicKey: PublicKey,
        timeout: Duration? = nil
    ) async throws -> Groups.Metadata? {
        try await fetchMetadata(for: group, authorPublicKey: Optional(authorPublicKey), timeout: timeout)
    }

    /// Fetches the group's full state snapshot from its relay, validated against
    /// `group.relayPublicKey` when the reference carries one. See
    /// ``NostrGroupManaging/fetchState(for:authorPublicKey:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - timeout: How long to wait for the relay to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The snapshot, with a nil field per kind the relay did not answer for.
    public func fetchState(for group: GroupReference, timeout: Duration? = nil) async throws -> GroupState {
        try await fetchState(for: group, authorPublicKey: nil, timeout: timeout)
    }

    /// Fetches the group's full state snapshot from its relay, validated against `authorPublicKey`.
    /// See ``NostrGroupManaging/fetchState(for:authorPublicKey:timeout:)-(_,PublicKey?,_)``.
    /// - Parameters:
    ///   - group: The group to query; its relay is added to the pool and connected on demand.
    ///   - authorPublicKey: The relay public key to validate against, overriding
    ///     `group.relayPublicKey`.
    ///   - timeout: How long to wait for the relay to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The snapshot, with a nil field per kind the relay did not answer for.
    public func fetchState(
        for group: GroupReference,
        authorPublicKey: PublicKey,
        timeout: Duration? = nil
    ) async throws -> GroupState {
        try await fetchState(for: group, authorPublicKey: Optional(authorPublicKey), timeout: timeout)
    }

    /// Subscribes to the group's whole live timeline — every content kind, no time bound, no
    /// limit. See ``NostrGroupManaging/timeline(_:kinds:since:limit:)-(_,[Event.Kind]?,_,_)``.
    /// - Parameter group: The group to follow; its relay is added to the pool and connected on
    ///   demand.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    public func timeline(_ group: GroupReference) async throws -> SubscriptionSequence {
        try await timeline(group, kinds: nil, since: nil, limit: nil)
    }

    /// Subscribes to the group's live timeline of the given content kinds. See
    /// ``NostrGroupManaging/timeline(_:kinds:since:limit:)-(_,[Event.Kind]?,_,_)``.
    /// - Parameters:
    ///   - group: The group to follow; its relay is added to the pool and connected on demand.
    ///   - kinds: The content kinds to receive.
    ///   - since: Only events whose `created_at` is at or after this time, if given.
    ///   - limit: The maximum number of stored events the relay should send, if given.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    public func timeline(
        _ group: GroupReference,
        kinds: [Event.Kind],
        since: Timestamp? = nil,
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        try await timeline(group, kinds: Optional(kinds), since: since, limit: limit)
    }

    /// Subscribes to the group's live timeline of every content kind from `since` on. See
    /// ``NostrGroupManaging/timeline(_:kinds:since:limit:)-(_,[Event.Kind]?,_,_)``.
    /// - Parameters:
    ///   - group: The group to follow; its relay is added to the pool and connected on demand.
    ///   - since: Only events whose `created_at` is at or after this time.
    ///   - limit: The maximum number of stored events the relay should send, if given.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    public func timeline(
        _ group: GroupReference,
        since: Timestamp,
        limit: Int? = nil
    ) async throws -> SubscriptionSequence {
        try await timeline(group, kinds: nil, since: Optional(since), limit: limit)
    }

    /// Subscribes to the group's live timeline of every content kind, with the relay sending up to
    /// `limit` stored events. See
    /// ``NostrGroupManaging/timeline(_:kinds:since:limit:)-(_,[Event.Kind]?,_,_)``.
    /// - Parameters:
    ///   - group: The group to follow; its relay is added to the pool and connected on demand.
    ///   - limit: The maximum number of stored events the relay should send.
    /// - Returns: The subscription as an async sequence of relay-aware events.
    public func timeline(_ group: GroupReference, limit: Int) async throws -> SubscriptionSequence {
        try await timeline(group, kinds: nil, since: nil, limit: Optional(limit))
    }

    /// Fetches the current user's kind-10009 simple group list, decrypting its private entries. See
    /// ``NostrGroupManaging/fetchSimpleGroupList(for:timeout:)-(PublicKey?,_)``.
    /// - Parameter timeout: How long to wait for relays to finish; `nil` uses
    ///   ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The typed list, or nil if none was found.
    public func fetchSimpleGroupList(timeout: Duration? = nil) async throws -> SimpleGroupList? {
        try await fetchSimpleGroupList(for: nil, timeout: timeout)
    }

    /// Fetches another user's kind-10009 simple group list, with only its public entries. See
    /// ``NostrGroupManaging/fetchSimpleGroupList(for:timeout:)-(PublicKey?,_)``.
    /// - Parameters:
    ///   - publicKey: The list's author.
    ///   - timeout: How long to wait for relays to finish; `nil` uses
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The typed list, or nil if none was found.
    public func fetchSimpleGroupList(
        for publicKey: PublicKey,
        timeout: Duration? = nil
    ) async throws -> SimpleGroupList? {
        try await fetchSimpleGroupList(for: Optional(publicKey), timeout: timeout)
    }

    /// Signs and publishes the current user's kind-10009 group list to the whole pool, waiting for
    /// the pool config's ``RelayPoolConfig/defaultPublishStrategy``. See
    /// ``NostrGroupManaging/publishSimpleGroupList(_:strategy:)``.
    /// - Parameter list: The list to publish.
    /// - Returns: The signed event together with the per-relay publish outcome.
    @discardableResult
    public func publishSimpleGroupList(_ list: SimpleGroupList) async throws -> PublishedEvent {
        try await publishSimpleGroupList(list, strategy: nil)
    }
}

// MARK: - Conveniences

extension NostrGroupManaging {
    /// Requests to join a group (kind 9021), built by
    /// ``EventTemplate/groupJoinRequest(groupID:inviteCode:reason:)`` and published only to the
    /// group's relay through ``NostrGroupManaging/publish(_:in:strategy:)``.
    ///
    /// The invite code applied is `inviteCode ?? group.inviteCode`, so a reference parsed from a
    /// share link with a "?invite=<code>" suffix works unchanged. Closed groups accept the request
    /// automatically for a valid code; otherwise an admin decides, and the relay reports an
    /// already-member state with a "duplicate:" OK message.
    /// - Parameters:
    ///   - group: The group to join; its relay is added to the pool and connected on demand.
    ///   - inviteCode: An invite code overriding `group.inviteCode`, if any.
    ///   - reason: An optional free-form message to the group's admins (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: The errors of ``NostrGroupManaging/publish(_:in:strategy:)``.
    @discardableResult
    public func join(
        _ group: GroupReference,
        inviteCode: String? = nil,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(
            .groupJoinRequest(groupID: group.id, inviteCode: inviteCode ?? group.inviteCode, reason: reason),
            in: group,
            strategy: strategy
        )
    }

    /// Requests to leave a group (kind 9022), built by
    /// ``EventTemplate/groupLeaveRequest(groupID:reason:)`` and published only to the group's relay
    /// through ``NostrGroupManaging/publish(_:in:strategy:)``; the relay answers by issuing a
    /// kind-9001 removal for the author.
    /// - Parameters:
    ///   - group: The group to leave; its relay is added to the pool and connected on demand.
    ///   - reason: An optional free-form message (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: The errors of ``NostrGroupManaging/publish(_:in:strategy:)``.
    @discardableResult
    public func leave(
        _ group: GroupReference,
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(.groupLeaveRequest(groupID: group.id, reason: reason), in: group, strategy: strategy)
    }

    /// Publishes a content event into a group, built by
    /// ``EventTemplate/groupContent(groupID:kind:content:tags:previous:)`` and published only to the
    /// group's relay through ``NostrGroupManaging/publish(_:in:strategy:)``.
    ///
    /// NIP-29 defines no content kinds of its own; the default kind is the NIP-C7 chat message
    /// (kind 9). The event's first tag is the group's "h" tag, followed by `tags`, then a "previous"
    /// tag when `previous` is non-empty. Timeline references stay a caller-supplied parameter —
    /// sample them from recently seen group events with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``; nothing is fetched behind your
    /// back.
    /// - Parameters:
    ///   - content: The event content.
    ///   - kind: The content kind (default: ``Event/Kind/chatMessage``).
    ///   - group: The group to post into; its relay is added to the pool and connected on demand.
    ///   - tags: Additional tags, appended after the "h" tag in order.
    ///   - previous: Timeline references for a trailing "previous" tag. Omitted when empty.
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: The errors of ``NostrGroupManaging/publish(_:in:strategy:)``.
    @discardableResult
    public func publishMessage(
        _ content: String,
        kind: Event.Kind = .chatMessage,
        in group: GroupReference,
        tags: [Tag] = [],
        previous: [String] = [],
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(
            .groupContent(groupID: group.id, kind: kind, content: content, tags: tags, previous: previous),
            in: group,
            strategy: strategy
        )
    }

    /// Publishes a moderation action (kinds 9000-9002, 9005, 9007-9010), built by
    /// ``EventTemplate/groupModeration(_:groupID:previous:reason:)`` and published only to the
    /// group's relay through ``NostrGroupManaging/publish(_:in:strategy:)``; the relay enforces the
    /// author's role permissions and answers with an OK message.
    ///
    /// See ``Groups/ModerationAction`` for the actions and their tag layouts. Timeline references
    /// stay a caller-supplied parameter — sample them with
    /// ``Groups/previousReferences(from:excludingAuthor:maxCount:)``.
    /// - Parameters:
    ///   - action: The moderation action to request.
    ///   - group: The group to moderate; its relay is added to the pool and connected on demand.
    ///   - previous: Timeline references for a trailing "previous" tag. Omitted when empty.
    ///   - reason: An optional human-readable reason (the event content).
    ///   - strategy: How many relay acknowledgments to wait for before returning
    ///     (default: the pool config's ``RelayPoolConfig/defaultPublishStrategy``).
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: The errors of ``NostrGroupManaging/publish(_:in:strategy:)``.
    @discardableResult
    public func publishModeration(
        _ action: Groups.ModerationAction,
        in group: GroupReference,
        previous: [String] = [],
        reason: String? = nil,
        strategy: PublishStrategy? = nil
    ) async throws -> PublishedEvent {
        try await publish(
            .groupModeration(action, groupID: group.id, previous: previous, reason: reason),
            in: group,
            strategy: strategy
        )
    }
}
