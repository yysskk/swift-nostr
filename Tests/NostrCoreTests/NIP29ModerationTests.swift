import Foundation
import NostrCore
import NostrTestSupport
import Testing

/// A moderation-event literal for parsing tests that never reach signature checks.
private func makeEvent(
    kind: Event.Kind,
    tags: [[String]] = [],
    content: String = ""
) -> Event {
    Event(
        id: EventID(String(repeating: "a", count: 64))!,
        pubkey: PublicKey.fixture("admin"),
        createdAt: Timestamp(rawValue: 1_700_000_000),
        kind: kind,
        tags: tags,
        content: content,
        signature: nil
    )
}

@Suite("NIP-29 Moderation Builders")
struct NIP29ModerationBuilderTests {
    let createdAt = Timestamp(rawValue: 1_700_000_000)
    let target = PublicKey.fixture("target")

    @Test("every action maps to its spec kind")
    func actionKinds() {
        #expect(Groups.ModerationAction.putUser(pubkey: target, roles: []).kind == .groupPutUser)
        #expect(Groups.ModerationAction.removeUser(pubkey: target).kind == .groupRemoveUser)
        #expect(
            Groups.ModerationAction.editMetadata(Groups.Metadata(groupID: "abcdef")).kind
                == .groupEditMetadata)
        #expect(Groups.ModerationAction.deleteEvent(id: EventID.fixture("deleted")).kind == .groupDeleteEvent)
        #expect(Groups.ModerationAction.createGroup.kind == .groupCreation)
        #expect(Groups.ModerationAction.deleteGroup.kind == .groupDeletion)
        #expect(Groups.ModerationAction.createInvite(code: "invite123").kind == .groupCreateInvite)
        #expect(Groups.ModerationAction.updatePinList([]).kind == .groupUpdatePinList)
    }

    /// Converting a `Date` that is infinite or beyond `Int64` used to trap inside the builder.
    @Test(
        "a moderation event takes an extreme timestamp without trapping",
        arguments: [
            Timestamp(rawValue: Int64.max), Timestamp(rawValue: Int64.min),
            Timestamp(Date(timeIntervalSince1970: -.infinity)),
        ]
    )
    func extremeTimestamp(createdAt: Timestamp) async throws {
        let unsigned = Groups.moderationEvent(
            .deleteGroup, groupID: "abcdef", pubkey: PublicKey.fixture("admin"), createdAt: createdAt)
        #expect(unsigned.createdAt == createdAt)

        let signed = try await Groups.moderationEvent(
            .deleteGroup, groupID: "abcdef", createdAt: createdAt, signer: EventSigner(keyPair: try KeyPair()))
        #expect(signed.createdAt == createdAt)
        #expect(try signed.verify())
    }

    @Test("a put-user event carries the p tag with roles after the h tag")
    func putUserLayout() {
        let unsigned = Groups.moderationEvent(
            .putUser(pubkey: target, roles: ["ceo", "gardener"]),
            groupID: "abcdef",
            pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt
        )

        #expect(unsigned.kind == .groupPutUser)
        #expect(unsigned.pubkey == PublicKey.fixture("admin"))
        #expect(unsigned.createdAt.rawValue == 1_700_000_000)
        #expect(unsigned.tags == [["h", "abcdef"], ["p", target.hex, "ceo", "gardener"]])
        #expect(unsigned.content.isEmpty)
    }

    @Test("a role-less put-user and a remove-user both emit a bare p tag")
    func bareUserTags() {
        let put = Groups.moderationEvent(
            .putUser(pubkey: target, roles: []), groupID: "abcdef", pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt)
        #expect(put.tags == [["h", "abcdef"], ["p", target.hex]])

        let remove = Groups.moderationEvent(
            .removeUser(pubkey: target), groupID: "abcdef", reason: "spam", pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt)
        #expect(remove.kind == .groupRemoveUser)
        #expect(remove.tags == [["h", "abcdef"], ["p", target.hex]])
        #expect(remove.content == "spam")
    }

    @Test("an edit-metadata event emits the metadata's field tags and never a d or second h tag")
    func editMetadataLayout() {
        let metadata = Groups.Metadata(
            groupID: "ignored",
            name: "Pizza Lovers",
            about: "a group for people who love pizza",
            isPrivate: true,
            isClosed: true
        )

        let unsigned = Groups.moderationEvent(
            .editMetadata(metadata), groupID: "abcdef", pubkey: PublicKey.fixture("admin"), createdAt: createdAt)

        #expect(unsigned.kind == .groupEditMetadata)
        #expect(
            unsigned.tags == [
                ["h", "abcdef"],
                ["name", "Pizza Lovers"],
                ["about", "a group for people who love pizza"],
                ["private"],
                ["closed"],
            ])
        #expect(unsigned.tags.allSatisfy { $0.first != "d" })
        #expect(unsigned.tags.filter { $0.first == "h" } == [["h", "abcdef"]])
    }

    @Test("delete-event and create-invite carry their e and code tags")
    func deleteEventAndInviteLayouts() {
        let id = EventID.fixture("deleted")
        let deletion = Groups.moderationEvent(
            .deleteEvent(id: id), groupID: "abcdef", reason: "off topic", pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt)
        #expect(deletion.kind == .groupDeleteEvent)
        #expect(deletion.tags == [["h", "abcdef"], ["e", id.hex]])
        #expect(deletion.content == "off topic")

        let invite = Groups.moderationEvent(
            .createInvite(code: "invite123"), groupID: "abcdef", pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt)
        #expect(invite.kind == .groupCreateInvite)
        #expect(invite.tags == [["h", "abcdef"], ["code", "invite123"]])
    }

    @Test("create-group and delete-group carry only the h tag")
    func lifecycleLayouts() {
        let create = Groups.moderationEvent(
            .createGroup, groupID: "abcdef", pubkey: PublicKey.fixture("admin"), createdAt: createdAt)
        #expect(create.kind == .groupCreation)
        #expect(create.tags == [["h", "abcdef"]])
        #expect(create.content.isEmpty)

        let delete = Groups.moderationEvent(
            .deleteGroup, groupID: "abcdef", pubkey: PublicKey.fixture("admin"), createdAt: createdAt)
        #expect(delete.kind == .groupDeletion)
        #expect(delete.tags == [["h", "abcdef"]])
    }

    @Test("update-pin-list preserves the interleaved order of e and a items")
    func pinListLayout() {
        let first = EventID.fixture("first")
        let second = EventID.fixture("second")
        let address = "39000:\(String(repeating: "b", count: 64)):abcdef"

        let unsigned = Groups.moderationEvent(
            .updatePinList([.event(id: first), .address(address), .event(id: second)]),
            groupID: "abcdef",
            pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt
        )

        #expect(unsigned.kind == .groupUpdatePinList)
        #expect(unsigned.tags == [["h", "abcdef"], ["e", first.hex], ["a", address], ["e", second.hex]])

        let cleared = Groups.moderationEvent(
            .updatePinList([]), groupID: "abcdef", pubkey: PublicKey.fixture("admin"), createdAt: createdAt)
        #expect(cleared.tags == [["h", "abcdef"]])
    }

    @Test("previous references are appended last and only when non-empty")
    func previousPlacement() {
        let unsigned = Groups.moderationEvent(
            .putUser(pubkey: target, roles: ["member"]),
            groupID: "abcdef",
            previous: ["00000001", "00000002", "00000003"],
            pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt
        )

        #expect(
            unsigned.tags == [
                ["h", "abcdef"],
                ["p", target.hex, "member"],
                ["previous", "00000001", "00000002", "00000003"],
            ])

        let bare = Groups.moderationEvent(
            .putUser(pubkey: target, roles: ["member"]), groupID: "abcdef", pubkey: PublicKey.fixture("admin"),
            createdAt: createdAt)
        #expect(bare.tags.allSatisfy { $0.first != "previous" })
    }

    @Test("a signed moderation event verifies and keeps the unsigned layout")
    func signedModeration() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await Groups.moderationEvent(
            .removeUser(pubkey: target),
            groupID: "abcdef",
            reason: "spam",
            createdAt: createdAt,
            signer: signer
        )

        #expect(event.kind == .groupRemoveUser)
        #expect(event.pubkey == signer.publicKey)
        #expect(event.createdAt.rawValue == 1_700_000_000)
        #expect(event.tags == [["h", "abcdef"], ["p", target.hex]])
        #expect(event.content == "spam")
        #expect(try event.verify())
    }
}

@Suite("NIP-29 Moderation Parsing")
struct NIP29ModerationParsingTests {
    let createdAt = Timestamp(rawValue: 1_700_000_000)
    let target = PublicKey.fixture("target")

    /// Builds and signs a moderation event at a pinned timestamp.
    private func signedModeration(
        _ action: Groups.ModerationAction,
        groupID: String = "abcdef",
        previous: [String] = [],
        reason: String? = nil
    ) throws -> Event {
        let signer = EventSigner(keyPair: try KeyPair())
        return try signer.sign(
            Groups.moderationEvent(
                action,
                groupID: groupID,
                previous: previous,
                reason: reason,
                pubkey: signer.publicKey,
                createdAt: createdAt
            )
        )
    }

    @Test("a put-user event round-trips with roles, reason, and previous references")
    func putUserRoundTrip() throws {
        let event = try signedModeration(
            .putUser(pubkey: target, roles: ["ceo", "gardener"]),
            previous: ["00000001", "00000002"],
            reason: "welcome"
        )

        let request = try Groups.ModerationRequest(event: event)

        #expect(request.action == .putUser(pubkey: target, roles: ["ceo", "gardener"]))
        #expect(request.groupID == "abcdef")
        #expect(request.reason == "welcome")
        #expect(request.previousReferences == ["00000001", "00000002"])
    }

    @Test("a remove-user event round-trips and an empty content parses to a nil reason")
    func removeUserRoundTrip() throws {
        let request = try Groups.ModerationRequest(event: try signedModeration(.removeUser(pubkey: target)))

        #expect(request.action == .removeUser(pubkey: target))
        #expect(request.groupID == "abcdef")
        #expect(request.reason == nil)
        #expect(request.previousReferences.isEmpty)
    }

    @Test("an edit-metadata event round-trips with the h value as the parsed group id")
    func editMetadataRoundTrip() throws {
        let built = Groups.Metadata(
            groupID: "ignored",
            name: "Pizza Lovers",
            about: "a group for people who love pizza",
            isPrivate: true,
            isRestricted: true,
            supportedKinds: [.chatMessage, .thread],
            additionalTags: [Event.Tag(name: "alt", values: ["pizza group"])]
        )
        let event = try signedModeration(.editMetadata(built), previous: ["00000001"])

        let request = try Groups.ModerationRequest(event: event)

        var expected = built
        expected.groupID = "abcdef"
        #expect(request.action == .editMetadata(expected))
        #expect(request.previousReferences == ["00000001"])
        if case .editMetadata(let parsed) = request.action {
            #expect(parsed.additionalTags.map(\.rawArray) == [["alt", "pizza group"]])
            #expect(parsed.additionalTags.allSatisfy { !["h", "previous"].contains($0.name) })
        } else {
            Issue.record("Expected an edit-metadata action, got \(request.action)")
        }
    }

    @Test("a delete-event round-trips its target id and reason")
    func deleteEventRoundTrip() throws {
        let id = EventID.fixture("deleted")

        let request = try Groups.ModerationRequest(
            event: try signedModeration(.deleteEvent(id: id), reason: "off topic"))

        #expect(request.action == .deleteEvent(id: id))
        #expect(request.groupID == "abcdef")
        #expect(request.reason == "off topic")
    }

    @Test("create-group and delete-group round-trip without payload tags")
    func lifecycleRoundTrips() throws {
        let create = try Groups.ModerationRequest(event: try signedModeration(.createGroup))
        #expect(create.action == .createGroup)
        #expect(create.groupID == "abcdef")
        #expect(create.reason == nil)

        let delete = try Groups.ModerationRequest(event: try signedModeration(.deleteGroup, reason: "done"))
        #expect(delete.action == .deleteGroup)
        #expect(delete.reason == "done")
    }

    @Test("a create-invite round-trips its code")
    func createInviteRoundTrip() throws {
        let request = try Groups.ModerationRequest(
            event: try signedModeration(.createInvite(code: "invite123")))

        #expect(request.action == .createInvite(code: "invite123"))
        #expect(request.groupID == "abcdef")
    }

    @Test("an update-pin-list round-trips interleaved items and an empty list")
    func pinListRoundTrip() throws {
        let first = EventID.fixture("first")
        let second = EventID.fixture("second")
        let address = "39000:\(String(repeating: "b", count: 64)):abcdef"
        let items: [Groups.PinnedItem] = [.event(id: first), .address(address), .event(id: second)]

        let full = try Groups.ModerationRequest(
            event: try signedModeration(.updatePinList(items), previous: ["00000001"]))
        #expect(full.action == .updatePinList(items))
        #expect(full.previousReferences == ["00000001"])

        let cleared = try Groups.ModerationRequest(event: try signedModeration(.updatePinList([])))
        #expect(cleared.action == .updatePinList([]))
    }

    @Test("kinds outside the defined moderation set are rejected")
    func unsupportedKinds() {
        for raw in [1, 9003, 9004, 9006, 9011] {
            let kind = Event.Kind(rawValue: raw)
            let event = makeEvent(kind: kind, tags: [["h", "abcdef"], ["p", target.hex]])

            #expect(throws: Groups.ValidationError.unsupportedModerationKind(kind)) {
                try Groups.ModerationRequest(event: event)
            }
        }
    }

    @Test("the kind check precedes the group id check")
    func kindCheckedBeforeGroupID() {
        let event = makeEvent(kind: 9003)

        #expect(throws: Groups.ValidationError.unsupportedModerationKind(9003)) {
            try Groups.ModerationRequest(event: event)
        }
    }

    @Test("every moderation kind rejects a missing, bare, or empty h tag")
    func missingGroupID() {
        let kinds: [Event.Kind] = [
            .groupPutUser, .groupRemoveUser, .groupEditMetadata, .groupDeleteEvent,
            .groupCreation, .groupDeletion, .groupCreateInvite, .groupUpdatePinList,
        ]
        for kind in kinds {
            for tags in [[], [["h"]], [["h", ""]]] as [[[String]]] {
                let event = makeEvent(kind: kind, tags: tags + [["p", target.hex]])
                #expect(throws: Groups.ValidationError.missingGroupID(kind)) {
                    try Groups.ModerationRequest(event: event)
                }
            }
        }
    }

    @Test("put-user and remove-user require a p tag with a pubkey")
    func missingPubkeyTag() {
        for kind in [Event.Kind.groupPutUser, .groupRemoveUser] {
            let missing = makeEvent(kind: kind, tags: [["h", "abcdef"]])
            #expect(throws: Groups.ValidationError.missingTag(name: "p", kind: kind)) {
                try Groups.ModerationRequest(event: missing)
            }

            let valueless = makeEvent(kind: kind, tags: [["h", "abcdef"], ["p"]])
            #expect(throws: Groups.ValidationError.missingTag(name: "p", kind: kind)) {
                try Groups.ModerationRequest(event: valueless)
            }
        }
    }

    /// Moderation events are written by whoever signed them, so a target that is not a canonical
    /// key or id counts as no target at all.
    @Test("put-user and remove-user treat a malformed p value as a missing p tag")
    func malformedPubkeyTag() {
        for kind in [Event.Kind.groupPutUser, .groupRemoveUser] {
            for value in ["other", target.hex.uppercased(), String(target.hex.dropLast())] {
                let event = makeEvent(kind: kind, tags: [["h", "abcdef"], ["p", value]])
                #expect(throws: Groups.ValidationError.missingTag(name: "p", kind: kind)) {
                    try Groups.ModerationRequest(event: event)
                }
            }
        }
    }

    @Test("delete-event treats a malformed e value as a missing e tag")
    func malformedEventTag() {
        let event = makeEvent(kind: .groupDeleteEvent, tags: [["h", "abcdef"], ["e", "not-an-id"]])

        #expect(throws: Groups.ValidationError.missingTag(name: "e", kind: .groupDeleteEvent)) {
            try Groups.ModerationRequest(event: event)
        }
    }

    @Test("update-pin-list skips pinned events whose id is malformed")
    func pinListSkipsMalformedIDs() throws {
        let pinned = EventID.fixture("pinned")
        let event = makeEvent(
            kind: .groupUpdatePinList,
            tags: [["h", "abcdef"], ["e", "not-an-id"], ["e", pinned.hex], ["a", "39000:pubkey:abcdef"]]
        )

        #expect(
            try Groups.ModerationRequest(event: event).action
                == .updatePinList([.event(id: pinned), .address("39000:pubkey:abcdef")]))
    }

    @Test("delete-event requires an e tag")
    func missingEventTag() {
        let event = makeEvent(kind: .groupDeleteEvent, tags: [["h", "abcdef"]])

        #expect(throws: Groups.ValidationError.missingTag(name: "e", kind: .groupDeleteEvent)) {
            try Groups.ModerationRequest(event: event)
        }
    }

    @Test("create-invite requires a code tag with a non-empty value")
    func missingInviteCode() {
        for tags in [[["h", "abcdef"]], [["h", "abcdef"], ["code"]], [["h", "abcdef"], ["code", ""]]] {
            let event = makeEvent(kind: .groupCreateInvite, tags: tags)
            #expect(throws: Groups.ValidationError.missingTag(name: "code", kind: .groupCreateInvite)) {
                try Groups.ModerationRequest(event: event)
            }
        }
    }

    @Test("put-user takes the first p tag when several are present")
    func putUserFirstTagWins() throws {
        let event = makeEvent(
            kind: .groupPutUser,
            tags: [["h", "abcdef"], ["p", target.hex, "ceo"], ["p", "other", "member"]]
        )

        #expect(try Groups.ModerationRequest(event: event).action == .putUser(pubkey: target, roles: ["ceo"]))
    }

    @Test("remove-user ignores extra p tag values and later p tags")
    func removeUserExtras() throws {
        let event = makeEvent(
            kind: .groupRemoveUser,
            tags: [["h", "abcdef"], ["p", target.hex, "ceo"], ["p", "other"]]
        )

        #expect(try Groups.ModerationRequest(event: event).action == .removeUser(pubkey: target))
    }

    @Test("the new validation errors describe the tag and kind")
    func errorDescriptions() {
        let missing = Groups.ValidationError.missingTag(name: "p", kind: .groupPutUser)
        #expect(missing.errorDescription?.contains("p tag") == true)
        #expect(missing.errorDescription?.contains("9000") == true)

        let unsupported = Groups.ValidationError.unsupportedModerationKind(9003)
        #expect(unsupported.errorDescription?.contains("9003") == true)
        #expect(unsupported.errorDescription?.contains("moderation") == true)
    }
}
