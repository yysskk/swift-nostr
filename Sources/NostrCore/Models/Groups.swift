import Foundation

/// NIP-29 relay-based groups: group state and membership managed by a single relay.
///
/// A group lives on one relay and is identified by a short random-string id. Users
/// participate by sending ordinary events that carry the group id in an "h" tag; the relay
/// enforces membership and permissions, and publishes the group's state (metadata, admins,
/// members, roles) as relay-signed kind-39xxx events that clients only parse. Private
/// groups additionally require NIP-42 AUTH before the relay serves their events.
///
/// ```swift
/// let join = try await Groups.joinRequest(groupID: "abcdef", signer: signer)
/// let message = try await Groups.contentEvent(
///     groupID: "abcdef",
///     kind: .chatMessage,
///     content: "hello",
///     previous: Groups.previousReferences(from: recentEvents),
///     signer: signer
/// )
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public enum Groups {
    // MARK: - Membership Requests

    /// Builds an unsigned kind-9021 request to join a group.
    ///
    /// The event's first tag is the group's "h" tag, followed by a "code" tag when
    /// `inviteCode` is given. Closed groups accept the request automatically for a valid
    /// invite code; otherwise an admin decides.
    ///
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - inviteCode: An invite code to join a closed group without admin approval, if any.
    ///   - reason: An optional free-form message to the group's admins; becomes the event
    ///     content ("" when nil).
    ///   - pubkey: The requesting user's public key (hex).
    ///   - createdAt: The event timestamp. Defaults to now.
    /// - Returns: The unsigned kind-9021 event.
    public static func joinRequest(
        groupID: String,
        inviteCode: String? = nil,
        reason: String? = nil,
        pubkey: String,
        createdAt: Date = Date()
    ) -> UnsignedEvent {
        var tags: [Tag] = [.group(groupID)]
        if let inviteCode {
            tags.append(.inviteCode(inviteCode))
        }
        return UnsignedEvent(
            pubkey: pubkey,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            kind: .groupJoinRequest,
            tags: tags,
            content: reason ?? ""
        )
    }

    /// Builds and signs a kind-9021 request to join a group.
    ///
    /// See ``joinRequest(groupID:inviteCode:reason:pubkey:createdAt:)`` for the event
    /// layout; the author is resolved from `signer`.
    ///
    /// - Returns: The signed kind-9021 event.
    /// - Throws: Whatever `signer` throws while resolving its public key or signing.
    public static func joinRequest(
        groupID: String,
        inviteCode: String? = nil,
        reason: String? = nil,
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> Event {
        try await signer.sign(
            joinRequest(
                groupID: groupID,
                inviteCode: inviteCode,
                reason: reason,
                pubkey: try await signer.publicKey,
                createdAt: createdAt
            )
        )
    }

    /// Builds an unsigned kind-9022 request to leave a group.
    ///
    /// The event carries the group's "h" tag; the relay answers by issuing a kind-9001
    /// removal for the author.
    ///
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - reason: An optional free-form message; becomes the event content ("" when nil).
    ///   - pubkey: The leaving user's public key (hex).
    ///   - createdAt: The event timestamp. Defaults to now.
    /// - Returns: The unsigned kind-9022 event.
    public static func leaveRequest(
        groupID: String,
        reason: String? = nil,
        pubkey: String,
        createdAt: Date = Date()
    ) -> UnsignedEvent {
        UnsignedEvent(
            pubkey: pubkey,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            kind: .groupLeaveRequest,
            tags: [.group(groupID)],
            content: reason ?? ""
        )
    }

    /// Builds and signs a kind-9022 request to leave a group.
    ///
    /// See ``leaveRequest(groupID:reason:pubkey:createdAt:)`` for the event layout; the
    /// author is resolved from `signer`.
    ///
    /// - Returns: The signed kind-9022 event.
    /// - Throws: Whatever `signer` throws while resolving its public key or signing.
    public static func leaveRequest(
        groupID: String,
        reason: String? = nil,
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> Event {
        try await signer.sign(
            leaveRequest(
                groupID: groupID,
                reason: reason,
                pubkey: try await signer.publicKey,
                createdAt: createdAt
            )
        )
    }

    // MARK: - Group-Scoped Content

    /// Builds an unsigned event of any kind scoped to a group.
    ///
    /// NIP-29 defines no content kinds of its own — pass e.g. ``Event/Kind/chatMessage``
    /// (NIP-C7) or ``Event/Kind/thread`` (NIP-7D). The event's first tag is the group's "h"
    /// tag, followed by `tags` in order, then a "previous" tag only when `previous` is
    /// non-empty.
    ///
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - kind: The content kind, e.g. ``Event/Kind/chatMessage``.
    ///   - content: The event content.
    ///   - tags: Additional tags, appended after the "h" tag in order.
    ///   - previous: Timeline references for a trailing "previous" tag, e.g. from
    ///     ``previousReferences(from:excludingAuthor:maxCount:)``. Omitted when empty.
    ///   - pubkey: The author's public key (hex).
    ///   - createdAt: The event timestamp. Defaults to now.
    /// - Returns: The unsigned group-scoped event.
    public static func contentEvent(
        groupID: String,
        kind: Event.Kind,
        content: String,
        tags: [Tag] = [],
        previous: [String] = [],
        pubkey: String,
        createdAt: Date = Date()
    ) -> UnsignedEvent {
        var allTags: [Tag] = [.group(groupID)]
        allTags.append(contentsOf: tags)
        if !previous.isEmpty {
            allTags.append(.previous(previous))
        }
        return UnsignedEvent(
            pubkey: pubkey,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            kind: kind,
            tags: allTags,
            content: content
        )
    }

    /// Builds and signs an event of any kind scoped to a group.
    ///
    /// See ``contentEvent(groupID:kind:content:tags:previous:pubkey:createdAt:)`` for the
    /// event layout; the author is resolved from `signer`.
    ///
    /// - Returns: The signed group-scoped event.
    /// - Throws: Whatever `signer` throws while resolving its public key or signing.
    public static func contentEvent(
        groupID: String,
        kind: Event.Kind,
        content: String,
        tags: [Tag] = [],
        previous: [String] = [],
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> Event {
        try await signer.sign(
            contentEvent(
                groupID: groupID,
                kind: kind,
                content: content,
                tags: tags,
                previous: previous,
                pubkey: try await signer.publicKey,
                createdAt: createdAt
            )
        )
    }

    // MARK: - Timeline References ("previous")

    /// The NIP-29 timeline reference for an event id: its first 8 characters (shorter ids
    /// are returned whole).
    public static func previousReference(forEventID id: String) -> String {
        String(id.prefix(8))
    }

    /// Samples timeline references for a "previous" tag from recently seen group events.
    ///
    /// Forwards to
    /// ``previousReferences(from:excludingAuthor:maxCount:using:)`` with the system
    /// random number generator; the spec recommends carrying at least 3 references.
    ///
    /// - Returns: Up to `maxCount` distinct references from the newest 50 of `events`.
    public static func previousReferences(
        from events: some Sequence<Event>,
        excludingAuthor pubkey: String? = nil,
        maxCount: Int = 3
    ) -> [String] {
        var generator = SystemRandomNumberGenerator()
        return previousReferences(
            from: events, excludingAuthor: pubkey, maxCount: maxCount, using: &generator)
    }

    /// Samples timeline references for a "previous" tag, with injectable randomness.
    ///
    /// The sampling is deterministic given `generator`:
    /// 1. Order `events` by `createdAt` descending, breaking ties by `id` ascending.
    /// 2. Take the first 50 — the window the spec samples from — then drop events authored
    ///    by `pubkey`.
    /// 3. Sample `min(maxCount, remaining)` distinct events uniformly without replacement
    ///    (a partial Fisher–Yates shuffle driven by `generator`); a negative `maxCount` is
    ///    treated as 0.
    /// 4. Map each sampled event to ``previousReference(forEventID:)``.
    ///
    /// Sampling randomly across the window — rather than always referencing the newest
    /// events — makes an out-of-context rebroadcast of the event detectable.
    ///
    /// - Parameters:
    ///   - events: Recently seen group events, in any order.
    ///   - pubkey: An author whose events are never referenced — pass the sender's own
    ///     public key. Nil excludes nothing.
    ///   - maxCount: The maximum number of references; the spec recommends at least 3.
    ///   - generator: The source of randomness; inject a seeded generator for
    ///     reproducible sampling.
    /// - Returns: The sampled references, e.g. for ``Event/Tag/previous(_:)``.
    public static func previousReferences(
        from events: some Sequence<Event>,
        excludingAuthor pubkey: String? = nil,
        maxCount: Int = 3,
        using generator: inout some RandomNumberGenerator
    ) -> [String] {
        let window =
            events
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.id < rhs.id
            }
            .prefix(50)
        var candidates = window.filter { $0.pubkey != pubkey }
        let count = min(max(maxCount, 0), candidates.count)
        var references: [String] = []
        references.reserveCapacity(count)
        for index in 0..<count {
            let swapIndex = Int.random(in: index..<candidates.count, using: &generator)
            candidates.swapAt(index, swapIndex)
            references.append(previousReference(forEventID: candidates[index].id))
        }
        return references
    }

    /// The timeline references carried by an event's "previous" tag ([] when absent).
    public static func previousReferences(of event: Event) -> [String] {
        event.tags(named: "previous").first?.values ?? []
    }

    /// The references of `event` that match none of `knownEventIDs`.
    ///
    /// A reference matches when it equals the first 8 characters of a known event id — the
    /// spec's reference length — so references of any other length are reported unknown. A
    /// non-empty result means the timeline may be forged: the spec asks clients to verify
    /// references against events they have seen "to keep relays honest".
    ///
    /// - Parameters:
    ///   - event: The event whose "previous" tag to check.
    ///   - knownEventIDs: The ids of events already seen in the group.
    /// - Returns: The references matching no known id ([] when all are known).
    public static func unknownPreviousReferences(
        of event: Event,
        knownEventIDs: some Sequence<String>
    ) -> [String] {
        let knownReferences = Set(knownEventIDs.map { String($0.prefix(8)) })
        return previousReferences(of: event).filter { !knownReferences.contains($0) }
    }
}

// MARK: - Event Accessor
extension Event {
    /// The NIP-29 group id this event belongs to: the first "h" tag value, or — for
    /// relay-generated group state (kinds 39000-39005) — the "d" tag value. Nil for events
    /// carrying neither.
    public var groupID: String? {
        if let groupID = firstTagValue(named: "h") {
            return groupID
        }
        if (39000...39005).contains(kind.rawValue) {
            return firstTagValue(named: "d")
        }
        return nil
    }
}
