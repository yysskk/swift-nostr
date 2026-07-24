import Foundation

// MARK: - Moderation Actions (kinds 9000-9002, 9005, 9007-9010)
extension Groups {
    /// A typed NIP-29 moderation action (kinds 9000-9002, 9005, 9007-9010), performed by a group admin or
    /// the relay itself.
    ///
    /// Sending an action asks the relay to apply it: the relay checks the author's role
    /// permissions and answers with an OK message. Build the event for an action with
    /// ``Groups/moderationEvent(_:groupID:previous:reason:pubkey:createdAt:)`` and parse
    /// received ones with ``Groups/ModerationRequest``.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public enum ModerationAction: Sendable, Hashable {
        /// kind 9000 — adds `pubkey` to the group and/or replaces their role names.
        case putUser(pubkey: String, roles: [String])
        /// kind 9001 — removes `pubkey` from the group.
        case removeUser(pubkey: String)
        /// kind 9002 — replaces the group's metadata with `Metadata`'s ``Metadata/fieldTags``
        /// (the embedded ``Metadata/groupID`` is not emitted; the event's "h" tag carries the
        /// group).
        case editMetadata(Metadata)
        /// kind 9005 — deletes the event with this id from the group.
        case deleteEvent(id: String)
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
        fileprivate var actionTags: [Tag] {
            switch self {
            case .putUser(let pubkey, let roles):
                return [.pubkey(pubkey, roles: roles)]
            case .removeUser(let pubkey):
                return [.pubkey(pubkey, roles: [])]
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
                        return Tag(name: "a", values: [address])
                    }
                }
            }
        }
    }

    /// Builds an unsigned NIP-29 moderation event.
    ///
    /// The event's first tag is the group's "h" tag, followed by the action's tags —
    /// `["p", pubkey, role...]` for ``ModerationAction/putUser(pubkey:roles:)``,
    /// `["p", pubkey]` for ``ModerationAction/removeUser(pubkey:)``, the metadata's
    /// ``Metadata/fieldTags`` for ``ModerationAction/editMetadata(_:)``, `["e", id]` for
    /// ``ModerationAction/deleteEvent(id:)``, `["code", code]` for
    /// ``ModerationAction/createInvite(code:)``, the "e"/"a" tags in pin order for
    /// ``ModerationAction/updatePinList(_:)``, and none for ``ModerationAction/createGroup``
    /// and ``ModerationAction/deleteGroup`` — then a "previous" tag only when `previous` is
    /// non-empty.
    ///
    /// - Parameters:
    ///   - action: The moderation action to request.
    ///   - groupID: The group's id on its relay.
    ///   - previous: Timeline references for a trailing "previous" tag, e.g. from
    ///     ``previousReferences(from:excludingAuthor:maxCount:)``. Omitted when empty.
    ///   - reason: An optional human-readable reason for the action; becomes the event
    ///     content ("" when nil).
    ///   - pubkey: The acting admin's public key (hex).
    ///   - createdAt: The event timestamp. Defaults to now.
    /// - Returns: The unsigned moderation event of ``ModerationAction/kind``.
    public static func moderationEvent(
        _ action: ModerationAction,
        groupID: String,
        previous: [String] = [],
        reason: String? = nil,
        pubkey: String,
        createdAt: Date = Date()
    ) -> UnsignedEvent {
        var tags: [Tag] = [.group(groupID)]
        tags.append(contentsOf: action.actionTags)
        if !previous.isEmpty {
            tags.append(.previous(previous))
        }
        return UnsignedEvent(
            pubkey: pubkey,
            createdAt: Int64(createdAt.timeIntervalSince1970),
            kind: action.kind,
            tags: tags,
            content: reason ?? ""
        )
    }

    /// Builds and signs a NIP-29 moderation event.
    ///
    /// See ``moderationEvent(_:groupID:previous:reason:pubkey:createdAt:)`` for the event
    /// layout; the author is resolved from `signer`.
    ///
    /// - Returns: The signed moderation event of ``ModerationAction/kind``.
    /// - Throws: Whatever `signer` throws while resolving its public key or signing.
    public static func moderationEvent(
        _ action: ModerationAction,
        groupID: String,
        previous: [String] = [],
        reason: String? = nil,
        createdAt: Date = Date(),
        signer: some NostrSigning
    ) async throws -> Event {
        try await signer.sign(
            moderationEvent(
                action,
                groupID: groupID,
                previous: previous,
                reason: reason,
                pubkey: try await signer.publicKey,
                createdAt: createdAt
            )
        )
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
        ///   absent.
        public init(event: Event) throws {
            guard Self.moderationKinds.contains(event.kind) else {
                throw ValidationError.unsupportedModerationKind(event.kind)
            }
            guard let groupID = event.firstTagValue(named: "h"), !groupID.isEmpty else {
                throw ValidationError.missingGroupID(event.kind)
            }

            switch event.kind {
            case .groupPutUser:
                guard let target = event.tags(named: "p").first, let pubkey = target.primaryValue else {
                    throw ValidationError.missingTag(name: "p", kind: event.kind)
                }
                action = .putUser(pubkey: pubkey, roles: Array(target.values.dropFirst()))
            case .groupRemoveUser:
                guard let pubkey = event.firstTagValue(named: "p") else {
                    throw ValidationError.missingTag(name: "p", kind: event.kind)
                }
                action = .removeUser(pubkey: pubkey)
            case .groupEditMetadata:
                action = .editMetadata(
                    Metadata(
                        groupID: groupID,
                        fieldTags: event.structuredTags.filter { !["h", "previous"].contains($0.name) }
                    )
                )
            case .groupDeleteEvent:
                guard let id = event.firstTagValue(named: "e") else {
                    throw ValidationError.missingTag(name: "e", kind: event.kind)
                }
                action = .deleteEvent(id: id)
            case .groupCreation:
                action = .createGroup
            case .groupDeletion:
                action = .deleteGroup
            case .groupCreateInvite:
                guard let code = event.firstTagValue(named: "code"), !code.isEmpty else {
                    throw ValidationError.missingTag(name: "code", kind: event.kind)
                }
                action = .createInvite(code: code)
            case .groupUpdatePinList:
                action = .updatePinList(
                    event.structuredTags.compactMap { tag in
                        switch tag.name {
                        case "e":
                            return tag.primaryValue.map { PinnedItem.event(id: $0) }
                        case "a":
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
