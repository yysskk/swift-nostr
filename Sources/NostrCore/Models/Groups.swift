import Foundation

/// NIP-29 relay-based groups: group state and membership managed by a single relay.
///
/// A group lives on one relay and is identified by a short random-string id. Users
/// participate by sending ordinary events that carry the group id in an "h" tag; the relay
/// enforces membership and permissions, and publishes the group's state (metadata, admins,
/// members, roles) as relay-signed kind-39xxx events that clients only parse. Private
/// groups additionally require NIP-42 AUTH before the relay serves their events.
///
/// `Groups` holds the timeline-reference helpers and the parsers for relay-generated state and
/// moderation events; the events a user sends are ``EventTemplate`` factories such as
/// ``EventTemplate/groupJoinRequest(groupID:inviteCode:reason:)`` and
/// ``EventTemplate/groupContent(groupID:kind:content:tags:previous:)``:
///
/// ```swift
/// let join = try await signer.sign(.groupJoinRequest(groupID: "abcdef"))
/// let message = try await signer.sign(
///     .groupContent(
///         groupID: "abcdef",
///         kind: .chatMessage,
///         content: "hello",
///         previous: Groups.previousReferences(from: recentEvents)
///     )
/// )
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public enum Groups {
    // MARK: - Timeline References ("previous")

    /// The NIP-29 timeline reference for an event id: the first 8 characters of its hex form.
    public static func previousReference(forEventID id: EventID) -> String {
        String(id.hex.prefix(8))
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
        excludingAuthor publicKey: PublicKey? = nil,
        maxCount: Int = 3
    ) -> [String] {
        var generator = SystemRandomNumberGenerator()
        return previousReferences(
            from: events, excludingAuthor: publicKey, maxCount: maxCount, using: &generator)
    }

    /// Samples timeline references for a "previous" tag, with injectable randomness.
    ///
    /// The sampling is deterministic given `generator`:
    /// 1. Order `events` by `createdAt` descending, breaking ties by `id` ascending.
    /// 2. Take the first 50 — the window the spec samples from — then drop events authored
    ///    by `publicKey`.
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
    ///   - publicKey: An author whose events are never referenced — pass the sender's own
    ///     public key. Nil excludes nothing.
    ///   - maxCount: The maximum number of references; the spec recommends at least 3.
    ///   - generator: The source of randomness; inject a seeded generator for
    ///     reproducible sampling.
    /// - Returns: The sampled references, e.g. for ``Event/Tag/previous(_:)``.
    public static func previousReferences(
        from events: some Sequence<Event>,
        excludingAuthor publicKey: PublicKey? = nil,
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
        var candidates = window.filter { $0.publicKey != publicKey }
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
    /// A reference matches when it equals the first 8 hex characters of a known event id — the
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
        knownEventIDs: some Sequence<EventID>
    ) -> [String] {
        let knownReferences = Set(knownEventIDs.map(previousReference(forEventID:)))
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
