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
        publicKey: PublicKey.fixture("admin"),
        createdAt: Timestamp(rawValue: 1_700_000_000),
        kind: kind,
        tags: tags,
        content: content,
        signature: nil
    )
}

@Suite("NIP-29 Moderation Templates")
struct NIP29ModerationTemplateTests {
    let createdAt = Timestamp(rawValue: 1_700_000_000)
    let target = PublicKey.fixture("target")

    @Test("every action maps to its spec kind")
    func actionKinds() {
        #expect(Groups.ModerationAction.putUser(publicKey: target, roles: []).kind == .groupPutUser)
        #expect(Groups.ModerationAction.removeUser(publicKey: target).kind == .groupRemoveUser)
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
        "a moderation event signs at an extreme timestamp without trapping",
        arguments: [
            Timestamp(rawValue: Int64.max), Timestamp(rawValue: Int64.min),
            Timestamp(Date(timeIntervalSince1970: -.infinity)),
        ]
    )
    func extremeTimestamp(createdAt: Timestamp) throws {
        var template = EventTemplate.groupModeration(.deleteGroup, groupID: "abcdef")
        template.createdAt = createdAt

        let signed = try EventSigner(keyPair: try KeyPair()).sign(template)

        #expect(signed.createdAt == createdAt)
        #expect(try signed.verify())
    }

    @Test("a put-user event carries the p tag with roles after the h tag")
    func putUserLayout() {
        let template = EventTemplate.groupModeration(
            .putUser(publicKey: target, roles: ["ceo", "gardener"]), groupID: "abcdef")

        #expect(template.kind == .groupPutUser)
        #expect(template.tags.map(\.rawArray) == [["h", "abcdef"], ["p", target.hex, "ceo", "gardener"]])
        #expect(template.content.isEmpty)
    }

    @Test("a role-less put-user and a remove-user both emit a bare p tag")
    func bareUserTags() {
        let put = EventTemplate.groupModeration(.putUser(publicKey: target, roles: []), groupID: "abcdef")
        #expect(put.tags.map(\.rawArray) == [["h", "abcdef"], ["p", target.hex]])

        let remove = EventTemplate.groupModeration(.removeUser(publicKey: target), groupID: "abcdef", reason: "spam")
        #expect(remove.kind == .groupRemoveUser)
        #expect(remove.tags.map(\.rawArray) == [["h", "abcdef"], ["p", target.hex]])
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

        let template = EventTemplate.groupModeration(.editMetadata(metadata), groupID: "abcdef")

        let tags = template.tags.map(\.rawArray)
        #expect(template.kind == .groupEditMetadata)
        #expect(
            tags == [
                ["h", "abcdef"],
                ["name", "Pizza Lovers"],
                ["about", "a group for people who love pizza"],
                ["private"],
                ["closed"],
            ])
        #expect(tags.allSatisfy { $0.first != "d" })
        #expect(tags.filter { $0.first == "h" } == [["h", "abcdef"]])
    }

    @Test("delete-event and create-invite carry their e and code tags")
    func deleteEventAndInviteLayouts() {
        let id = EventID.fixture("deleted")
        let deletion = EventTemplate.groupModeration(.deleteEvent(id: id), groupID: "abcdef", reason: "off topic")
        #expect(deletion.kind == .groupDeleteEvent)
        #expect(deletion.tags.map(\.rawArray) == [["h", "abcdef"], ["e", id.hex]])
        #expect(deletion.content == "off topic")

        let invite = EventTemplate.groupModeration(.createInvite(code: "invite123"), groupID: "abcdef")
        #expect(invite.kind == .groupCreateInvite)
        #expect(invite.tags.map(\.rawArray) == [["h", "abcdef"], ["code", "invite123"]])
    }

    @Test("create-group and delete-group carry only the h tag")
    func lifecycleLayouts() {
        let create = EventTemplate.groupModeration(.createGroup, groupID: "abcdef")
        #expect(create.kind == .groupCreation)
        #expect(create.tags.map(\.rawArray) == [["h", "abcdef"]])
        #expect(create.content.isEmpty)

        let delete = EventTemplate.groupModeration(.deleteGroup, groupID: "abcdef")
        #expect(delete.kind == .groupDeletion)
        #expect(delete.tags.map(\.rawArray) == [["h", "abcdef"]])
    }

    @Test("update-pin-list preserves the interleaved order of e and a items")
    func pinListLayout() {
        let first = EventID.fixture("first")
        let second = EventID.fixture("second")
        let address = "39000:\(String(repeating: "b", count: 64)):abcdef"

        let template = EventTemplate.groupModeration(
            .updatePinList([.event(id: first), .address(address), .event(id: second)]), groupID: "abcdef")

        #expect(template.kind == .groupUpdatePinList)
        #expect(
            template.tags.map(\.rawArray) == [["h", "abcdef"], ["e", first.hex], ["a", address], ["e", second.hex]])

        let cleared = EventTemplate.groupModeration(.updatePinList([]), groupID: "abcdef")
        #expect(cleared.tags.map(\.rawArray) == [["h", "abcdef"]])
    }

    @Test("previous references are appended last and only when non-empty")
    func previousPlacement() {
        let template = EventTemplate.groupModeration(
            .putUser(publicKey: target, roles: ["member"]),
            groupID: "abcdef",
            previous: ["00000001", "00000002", "00000003"]
        )

        #expect(
            template.tags.map(\.rawArray) == [
                ["h", "abcdef"],
                ["p", target.hex, "member"],
                ["previous", "00000001", "00000002", "00000003"],
            ])

        let bare = EventTemplate.groupModeration(.putUser(publicKey: target, roles: ["member"]), groupID: "abcdef")
        #expect(bare.tags.allSatisfy { $0.name != "previous" })
    }

    @Test("a moderation event signed by a remote signer verifies and keeps the template layout")
    func signedModeration() async throws {
        let signer = StubRemoteSigner(keyPair: try KeyPair())
        var template = EventTemplate.groupModeration(.removeUser(publicKey: target), groupID: "abcdef", reason: "spam")
        template.createdAt = createdAt

        let event = try await signer.sign(template)

        #expect(event.kind == .groupRemoveUser)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(event.createdAt == createdAt)
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
        var template = EventTemplate.groupModeration(action, groupID: groupID, previous: previous, reason: reason)
        template.createdAt = createdAt
        return try EventSigner(keyPair: try KeyPair()).sign(template)
    }

    @Test("a put-user event round-trips with roles, reason, and previous references")
    func putUserRoundTrip() throws {
        let event = try signedModeration(
            .putUser(publicKey: target, roles: ["ceo", "gardener"]),
            previous: ["00000001", "00000002"],
            reason: "welcome"
        )

        let request = try Groups.ModerationRequest(event: event)

        #expect(request.action == .putUser(publicKey: target, roles: ["ceo", "gardener"]))
        #expect(request.groupID == "abcdef")
        #expect(request.reason == "welcome")
        #expect(request.previousReferences == ["00000001", "00000002"])
    }

    @Test("a remove-user event round-trips and an empty content parses to a nil reason")
    func removeUserRoundTrip() throws {
        let request = try Groups.ModerationRequest(event: try signedModeration(.removeUser(publicKey: target)))

        #expect(request.action == .removeUser(publicKey: target))
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

    @Test("put-user and remove-user require a p tag with a public key")
    func missingPublicKeyTag() {
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
    func malformedPublicKeyTag() {
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

    @Test("parse failures are thrown as the concrete ValidationError")
    func typedValidationError() {
        let event = makeEvent(kind: .groupDeleteEvent, tags: [["h", "abcdef"]])

        do {
            _ = try Groups.ModerationRequest(event: event)
            Issue.record("Expected a missing e tag")
        } catch {
            #expect(error == .missingTag(name: "e", kind: .groupDeleteEvent))
        }
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

        #expect(try Groups.ModerationRequest(event: event).action == .putUser(publicKey: target, roles: ["ceo"]))
    }

    @Test("remove-user ignores extra p tag values and later p tags")
    func removeUserExtras() throws {
        let event = makeEvent(
            kind: .groupRemoveUser,
            tags: [["h", "abcdef"], ["p", target.hex, "ceo"], ["p", "other"]]
        )

        #expect(try Groups.ModerationRequest(event: event).action == .removeUser(publicKey: target))
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
