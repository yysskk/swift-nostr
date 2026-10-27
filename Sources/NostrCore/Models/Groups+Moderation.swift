import Foundation

// MARK: - Moderation Actions (kinds 9000-9002, 9005, 9007-9010)
extension Groups {
    /// A typed NIP-29 moderation action (kinds 9000-9002, 9005, 9007-9010), performed by a group admin or
    /// the relay itself.
    ///
    /// Sending an action asks the relay to apply it: the relay checks the author's role
    /// permissions and answers with an OK message. Build the event for an action with
    /// ``EventTemplate/groupModeration(_:groupID:previous:reason:)`` and parse received ones with
    /// ``Groups/ModerationRequest``.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public enum ModerationAction: Sendable, Hashable {
        /// kind 9000 — adds `publicKey` to the group and/or replaces their role names.
        case putUser(publicKey: PublicKey, roles: [String])
        /// kind 9001 — removes `publicKey` from the group.
        case removeUser(publicKey: PublicKey)
        /// kind 9002 — replaces the group's metadata with `Metadata`'s ``Metadata/fieldTags``
        /// (the embedded ``Metadata/groupID`` is not emitted; the event's "h" tag carries the
        /// group).
        case editMetadata(Metadata)
        /// kind 9005 — deletes the event with this id from the group.
        case deleteEvent(id: EventID)
        /// kind 9007 — creates the group.
        case createGroup
        /// kind 9008 — deletes the group.
        case deleteGroup
        /// kind 9009 — creates an invite code for a closed group.
        case createInvite(code: String)
        /// kind 9010 — replaces the group's pin list with `items`, in order ([] clears it).
        case updatePinList([PinnedItem])

        /// The event kind the action maps to.
        public var kind: Event.Kind {
            switch self {
            case .putUser:
                return .groupPutUser
            case .removeUser:
                return .groupRemoveUser
            case .editMetadata:
                return .groupEditMetadata
            case .deleteEvent:
                return .groupDeleteEvent
            case .createGroup:
                return .groupCreation
            case .deleteGroup:
                return .groupDeletion
            case .createInvite:
                return .groupCreateInvite
            case .updatePinList:
                return .groupUpdatePinList
            }
        }

        /// The action-specific tags, emitted between the "h" tag and any "previous" tag.
        var actionTags: [Tag] {
            switch self {
            case .putUser(let publicKey, let roles):
                return [.publicKey(publicKey, roles: roles)]
            case .removeUser(let publicKey):
                return [.publicKey(publicKey, roles: [])]
            case .editMetadata(let metadata):
                return metadata.fieldTags
            case .deleteEvent(let id):
                return [.event(id)]
            case .createGroup, .deleteGroup:
                return []
            case .createInvite(let code):
                return [.inviteCode(code)]
            case .updatePinList(let items):
                return items.map { item in
                    switch item {
                    case .event(let id):
                        return .event(id)
                    case .address(let address):
                        return Tag(name: .address, values: [address])
                    }
                }
            }
        }
    }
}

// MARK: - Moderation Parsing
extension Groups {
    /// A parsed moderation event (kinds 9000-9002, 9005, 9007-9010), for admin and audit UIs.
    ///
    /// Never verifies the event signature — callers check ``Event/verify()`` themselves —
    /// and cannot know whether the relay honored the action; the group's relay-generated
    /// kind-39xxx state events are the authority on the outcome.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct ModerationRequest: Sendable, Hashable {
        /// The requested action, with its target parsed from the kind-specific tags.
        public let action: ModerationAction

        /// The id of the group the action applies to (the event's "h" tag).
        public let groupID: String

        /// The human-readable reason from the event content, or nil when it is empty.
        public let reason: String?

        /// The timeline references of the event's "previous" tag ([] when absent).
        public let previousReferences: [String]

        /// The eight moderation kinds the spec defines: 9000-9002, 9005, and 9007-9010.
        private static let moderationKinds: Set<Event.Kind> = [
            .groupPutUser, .groupRemoveUser, .groupEditMetadata, .groupDeleteEvent,
            .groupCreation, .groupDeletion, .groupCreateInvite, .groupUpdatePinList,
        ]

        /// Parses a moderation event of kinds 9000-9002, 9005, or 9007-9010.
        ///
        /// - Parameter event: The moderation event to parse.
        /// - Throws: ``ValidationError/unsupportedModerationKind(_:)`` for any other kind
        ///   (including 9003, 9004, and 9006, which the spec leaves undefined),
        ///   ``ValidationError/missingGroupID(_:)`` when no non-empty "h" tag is present,
        ///   or ``ValidationError/missingTag(name:kind:)`` when a tag the kind requires is
        ///   absent. A "p" or "e" target whose value is not a canonical hex public key or event
        ///   id counts as absent, and a pinned "e" item with such a value is skipped.
        public init(event: Event) throws(ValidationError) {
            guard Self.moderationKinds.contains(event.kind) else {
                throw ValidationError.unsupportedModerationKind(event.kind)
            }
            guard let groupID = event.firstTagValue(named: .group), !groupID.isEmpty else {
                throw ValidationError.missingGroupID(event.kind)
            }

            switch event.kind {
            case .groupPutUser:
                guard let target = event.tags(named: .publicKey).first,
                    let publicKey = target.primaryValue.flatMap(PublicKey.init)
                else {
                    throw ValidationError.missingTag(name: .publicKey, kind: event.kind)
                }
                action = .putUser(publicKey: publicKey, roles: Array(target.values.dropFirst()))
            case .groupRemoveUser:
                guard let publicKey = event.firstTagValue(named: .publicKey).flatMap(PublicKey.init) else {
                    throw ValidationError.missingTag(name: .publicKey, kind: event.kind)
                }
                action = .removeUser(publicKey: publicKey)
            case .groupEditMetadata:
                action = .editMetadata(
                    Metadata(
                        groupID: groupID,
                        fieldTags: event.tags.filter { ![.group, .previous].contains($0.name) }
                    )
                )
            case .groupDeleteEvent:
                guard let id = event.firstTagValue(named: .event).flatMap(EventID.init) else {
                    throw ValidationError.missingTag(name: .event, kind: event.kind)
                }
                action = .deleteEvent(id: id)
            case .groupCreation:
                action = .createGroup
            case .groupDeletion:
                action = .deleteGroup
            case .groupCreateInvite:
                guard let code = event.firstTagValue(named: .inviteCode), !code.isEmpty else {
                    throw ValidationError.missingTag(name: .inviteCode, kind: event.kind)
                }
                action = .createInvite(code: code)
            case .groupUpdatePinList:
                action = .updatePinList(
                    event.tags.compactMap { tag in
                        switch tag.name {
                        case .event:
                            return tag.primaryValue.flatMap(EventID.init).map { PinnedItem.event(id: $0) }
                        case .address:
                            return tag.primaryValue.map { PinnedItem.address($0) }
                        default:
                            return nil
                        }
                    }
                )
            default:
                throw ValidationError.unsupportedModerationKind(event.kind)
            }

            self.groupID = groupID
            reason = event.content.isEmpty ? nil : event.content
            previousReferences = Groups.previousReferences(of: event)
        }
    }
}
