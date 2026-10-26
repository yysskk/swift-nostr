import Foundation

// MARK: - Relay-based Groups (NIP-29)
extension EventTemplate {
    /// A request to join a group (kind 9021).
    ///
    /// The first tag is the group's "h" tag, followed by a "code" tag when `inviteCode` is given.
    /// Closed groups accept the request automatically for a valid invite code; otherwise an admin
    /// decides.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - inviteCode: An invite code to join a closed group without admin approval, if any.
    ///   - reason: A free-form message to the group's admins (the event content; "" when nil).
    /// - Returns: The template for the join request.
    public static func groupJoinRequest(
        groupID: String,
        inviteCode: String? = nil,
        reason: String? = nil
    ) -> EventTemplate {
        var tags: [Tag] = [.group(groupID)]
        if let inviteCode {
            tags.append(.inviteCode(inviteCode))
        }
        return EventTemplate(kind: .groupJoinRequest, tags: tags, content: reason ?? "")
    }

    /// A request to leave a group (kind 9022), carrying the group's "h" tag; the relay answers by
    /// issuing a kind-9001 removal for the author.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - reason: A free-form message (the event content; "" when nil).
    /// - Returns: The template for the leave request.
    public static func groupLeaveRequest(groupID: String, reason: String? = nil) -> EventTemplate {
        EventTemplate(kind: .groupLeaveRequest, tags: [.group(groupID)], content: reason ?? "")
    }

    /// An event of any kind scoped to a group.
    ///
    /// NIP-29 defines no content kinds of its own — pass e.g. ``Event/Kind/chatMessage`` (NIP-C7)
    /// or ``Event/Kind/thread`` (NIP-7D). The first tag is the group's "h" tag, followed by `tags`
    /// in order, then a "previous" tag only when `previous` is non-empty.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    /// - Parameters:
    ///   - groupID: The group's id on its relay.
    ///   - kind: The content kind, e.g. ``Event/Kind/chatMessage``.
    ///   - content: The event content.
    ///   - tags: Additional tags, appended after the "h" tag in order.
    ///   - previous: Timeline references for a trailing "previous" tag, e.g. from
    ///     ``Groups/previousReferences(from:excludingAuthor:maxCount:)``. Omitted when empty.
    /// - Returns: The template for the group-scoped event.
    public static func groupContent(
        groupID: String,
        kind: Event.Kind,
        content: String,
        tags: [Tag] = [],
        previous: [String] = []
    ) -> EventTemplate {
        var allTags: [Tag] = [.group(groupID)]
        allTags.append(contentsOf: tags)
        if !previous.isEmpty {
            allTags.append(.previous(previous))
        }
        return EventTemplate(kind: kind, tags: allTags, content: content)
    }

    /// A moderation action on a group (kinds 9000-9002, 9005, 9007-9010), of the action's
    /// ``Groups/ModerationAction/kind``.
    ///
    /// The first tag is the group's "h" tag, followed by the action's tags —
    /// `["p", publicKey, role...]` for ``Groups/ModerationAction/putUser(publicKey:roles:)``,
    /// `["p", publicKey]` for ``Groups/ModerationAction/removeUser(publicKey:)``, the metadata's
    /// ``Groups/Metadata/fieldTags`` for ``Groups/ModerationAction/editMetadata(_:)``, `["e", id]`
    /// for ``Groups/ModerationAction/deleteEvent(id:)``, `["code", code]` for
    /// ``Groups/ModerationAction/createInvite(code:)``, the "e"/"a" tags in pin order for
    /// ``Groups/ModerationAction/updatePinList(_:)``, and none for
    /// ``Groups/ModerationAction/createGroup`` and ``Groups/ModerationAction/deleteGroup`` — then
    /// a "previous" tag only when `previous` is non-empty.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    /// - Parameters:
    ///   - action: The moderation action to request.
    ///   - groupID: The group's id on its relay.
    ///   - previous: Timeline references for a trailing "previous" tag, e.g. from
    ///     ``Groups/previousReferences(from:excludingAuthor:maxCount:)``. Omitted when empty.
    ///   - reason: A human-readable reason for the action (the event content; "" when nil).
    /// - Returns: The template for the moderation event.
    public static func groupModeration(
        _ action: Groups.ModerationAction,
        groupID: String,
        previous: [String] = [],
        reason: String? = nil
    ) -> EventTemplate {
        var tags: [Tag] = [.group(groupID)]
        tags.append(contentsOf: action.actionTags)
        if !previous.isEmpty {
            tags.append(.previous(previous))
        }
        return EventTemplate(kind: action.kind, tags: tags, content: reason ?? "")
    }
}
