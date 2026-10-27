import Foundation
import NostrCore
import NostrTestSupport
import Testing

/// A deterministic linear congruential generator so sampling tests can pin exact output.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

/// Builds an event literal for tag parsing and sampling tests, where signature validity
/// is irrelevant.
private func makeEvent(
    id: EventID = EventID(String(repeating: "a", count: 64))!,
    publicKey: PublicKey = .fixture("pk"),
    createdAt: Timestamp = Timestamp(rawValue: 1_700_000_000),
    kind: Event.Kind = .chatMessage,
    tags: [Event.Tag] = []
) -> Event {
    Event(id: id, publicKey: publicKey, createdAt: createdAt, kind: kind, tags: tags, content: "", signature: nil)
}

/// The 64-character event id whose first 8 characters encode `index` in hex.
private func paddedID(_ index: Int) -> EventID {
    EventID(String(format: "%08x", index) + String(repeating: "0", count: 56))!
}

/// The 8-character timeline reference of the fixture event at `index`.
private func reference(_ index: Int) -> String {
    String(format: "%08x", index)
}

/// 60 events with ascending timestamps, ids carrying their index, and alternating authors.
private func timelineFixture() -> [Event] {
    (0..<60).map { index in
        makeEvent(
            id: paddedID(index),
            publicKey: .fixture(index.isMultiple(of: 2) ? "author-even" : "author-odd"),
            createdAt: Timestamp(rawValue: 1_700_000_000 + Int64(index))
        )
    }
}

@Suite("NIP-29 Group Kinds and Tags")
struct NIP29GroupKindAndTagTests {

    @Test("group kind constants carry the spec raw values")
    func kindRawValues() {
        #expect(Event.Kind.chatMessage.rawValue == 9)
        #expect(Event.Kind.thread.rawValue == 11)
        #expect(Event.Kind.groupPutUser.rawValue == 9000)
        #expect(Event.Kind.groupRemoveUser.rawValue == 9001)
        #expect(Event.Kind.groupEditMetadata.rawValue == 9002)
        #expect(Event.Kind.groupDeleteEvent.rawValue == 9005)
        #expect(Event.Kind.groupCreation.rawValue == 9007)
        #expect(Event.Kind.groupDeletion.rawValue == 9008)
        #expect(Event.Kind.groupCreateInvite.rawValue == 9009)
        #expect(Event.Kind.groupUpdatePinList.rawValue == 9010)
        #expect(Event.Kind.groupJoinRequest.rawValue == 9021)
        #expect(Event.Kind.groupLeaveRequest.rawValue == 9022)
        #expect(Event.Kind.simpleGroupList.rawValue == 10009)
        #expect(Event.Kind.groupMetadata.rawValue == 39000)
        #expect(Event.Kind.groupAdmins.rawValue == 39001)
        #expect(Event.Kind.groupMembers.rawValue == 39002)
        #expect(Event.Kind.groupRoles.rawValue == 39003)
        #expect(Event.Kind.groupPinList.rawValue == 39005)
    }

    @Test("group kinds fall in the expected NIP-01 ranges")
    func kindRanges() {
        let regular: [Event.Kind] = [
            .chatMessage, .thread, .groupPutUser, .groupEditMetadata, .groupUpdatePinList,
            .groupJoinRequest, .groupLeaveRequest,
        ]
        for kind in regular {
            #expect(!kind.isReplaceable)
            #expect(!kind.isEphemeral)
            #expect(!kind.isAddressable)
        }

        #expect(Event.Kind.simpleGroupList.isReplaceable)
        #expect(Event.Kind.groupMetadata.isAddressable)
        #expect(Event.Kind.groupPinList.isAddressable)
    }

    @Test("NIP-29 tag constructors produce the spec tag shapes")
    func tagConstructors() {
        #expect(Event.Tag.group("abcdef").rawArray == ["h", "abcdef"])
        #expect(
            Event.Tag.previous(["00000001", "00000002", "00000003"]).rawArray
                == ["previous", "00000001", "00000002", "00000003"])
        #expect(Event.Tag.inviteCode("invite123").rawArray == ["code", "invite123"])
        #expect(Event.Tag.role("admin").rawArray == ["role", "admin"])
        #expect(
            Event.Tag.role("admin", description: "Can edit metadata").rawArray
                == ["role", "admin", "Can edit metadata"])
        #expect(
            Event.Tag.simpleGroup(id: "abcdef", relayURL: RelayURL("wss://groups.example.com")!).rawArray
                == ["group", "abcdef", "wss://groups.example.com"])
        #expect(
            Event.Tag.simpleGroup(id: "abcdef", relayURL: RelayURL("wss://groups.example.com")!, name: "Cooking")
                .rawArray
                == ["group", "abcdef", "wss://groups.example.com", "Cooking"])
    }

    @Test("a p tag with roles appends them after the public key")
    func publicKeyRolesTag() {
        let pk = PublicKey.fixture("member")
        #expect(
            Event.Tag.publicKey(pk, roles: ["admin", "moderator"]).rawArray == ["p", pk.hex, "admin", "moderator"])
        #expect(Event.Tag.publicKey(pk, roles: []).rawArray == ["p", pk.hex])
    }
}

@Suite("NIP-29 Group Events")
struct NIP29GroupEventTests {
    let createdAt = Timestamp(rawValue: 1_700_000_000)

    // MARK: Join Requests

    @Test("a join request carries the h tag first, then the invite code, with the reason as content")
    func groupJoinRequest() {
        let template = EventTemplate.groupJoinRequest(groupID: "abcdef", inviteCode: "invite123", reason: "let me in")

        #expect(template.kind == .groupJoinRequest)
        #expect(template.tags.map(\.rawArray) == [["h", "abcdef"], ["code", "invite123"]])
        #expect(template.content == "let me in")
    }

    @Test("a join request without an invite code or reason has one tag and empty content")
    func groupJoinRequestDefaults() {
        let template = EventTemplate.groupJoinRequest(groupID: "abcdef")

        #expect(template.kind == .groupJoinRequest)
        #expect(template.tags.map(\.rawArray) == [["h", "abcdef"]])
        #expect(template.content.isEmpty)
    }

    /// Converting a `Date` that is infinite or beyond `Int64` used to trap inside the builders.
    @Test(
        "group templates sign at an extreme timestamp without trapping",
        arguments: [
            Timestamp(rawValue: Int64.max), Timestamp(rawValue: Int64.min),
            Timestamp(Date(timeIntervalSince1970: .infinity)), Timestamp(Date(timeIntervalSince1970: 1e300)),
        ]
    )
    func extremeTimestamps(createdAt: Timestamp) throws {
        let signer = EventSigner(keyPair: KeyPair())
        let templates: [EventTemplate] = [
            .groupJoinRequest(groupID: "abcdef"),
            .groupLeaveRequest(groupID: "abcdef"),
            .groupContent(groupID: "abcdef", kind: .chatMessage, content: "gm"),
        ]

        for var template in templates {
            template.createdAt = createdAt
            let signed = signer.sign(template)
            #expect(signed.createdAt == createdAt)
            try signed.verify()
        }
    }

    @Test("a join request signed by a remote signer verifies and keeps the template layout")
    func signedGroupJoinRequest() async throws {
        let signer = StubRemoteSigner(keyPair: KeyPair())
        var template = EventTemplate.groupJoinRequest(groupID: "abcdef", inviteCode: "invite123", reason: "let me in")
        template.createdAt = createdAt

        let event = try await signer.sign(template)

        #expect(event.kind == .groupJoinRequest)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(event.createdAt == createdAt)
        #expect(event.tags.map(\.rawArray) == [["h", "abcdef"], ["code", "invite123"]])
        #expect(event.content == "let me in")
        try event.verify()
    }

    // MARK: Leave Requests

    @Test("a leave request carries only the h tag, with the reason as content")
    func groupLeaveRequest() {
        let template = EventTemplate.groupLeaveRequest(groupID: "abcdef", reason: "goodbye")

        #expect(template.kind == .groupLeaveRequest)
        #expect(template.tags.map(\.rawArray) == [["h", "abcdef"]])
        #expect(template.content == "goodbye")
        #expect(EventTemplate.groupLeaveRequest(groupID: "abcdef").content.isEmpty)
    }

    @Test("a leave request signed by a remote signer verifies with kind 9022 and no code tag")
    func signedGroupLeaveRequest() async throws {
        let signer = StubRemoteSigner(keyPair: KeyPair())

        let event = try await signer.sign(.groupLeaveRequest(groupID: "abcdef"))

        #expect(event.kind == .groupLeaveRequest)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(event.tags.map(\.rawArray) == [["h", "abcdef"]])
        #expect(event.content.isEmpty)
        try event.verify()
    }

    // MARK: Group-Scoped Content

    @Test("groupContent puts the h tag first, then custom tags in order, then previous")
    func contentTagOrder() {
        let template = EventTemplate.groupContent(
            groupID: "abcdef",
            kind: .chatMessage,
            content: "hello",
            tags: [.hashtag("nostr"), .publicKey(PublicKey.fixture("pk1"))],
            previous: ["00000001", "00000002"]
        )

        #expect(template.kind == .chatMessage)
        #expect(template.content == "hello")
        #expect(
            template.tags.map(\.rawArray) == [
                ["h", "abcdef"],
                ["t", "nostr"],
                ["p", PublicKey.fixture("pk1").hex],
                ["previous", "00000001", "00000002"],
            ])
    }

    @Test("groupContent omits the previous tag when no references are given")
    func contentWithoutPrevious() {
        let template = EventTemplate.groupContent(groupID: "abcdef", kind: .chatMessage, content: "hello")

        #expect(template.tags.map(\.rawArray) == [["h", "abcdef"]])
    }

    @Test("groupContent honors arbitrary content kinds")
    func contentArbitraryKind() {
        let article = EventTemplate.groupContent(groupID: "abcdef", kind: Event.Kind(rawValue: 30023), content: "post")

        #expect(article.kind.rawValue == 30023)
        #expect(article.tags.map(\.rawArray) == [["h", "abcdef"]])
    }

    @Test("a content event signed by a remote signer verifies and keeps the template layout")
    func signedContent() async throws {
        let signer = StubRemoteSigner(keyPair: KeyPair())
        var template = EventTemplate.groupContent(
            groupID: "abcdef", kind: .chatMessage, content: "hello", previous: ["00000001"])
        template.createdAt = createdAt

        let event = try await signer.sign(template)

        #expect(event.kind == .chatMessage)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(event.createdAt == createdAt)
        #expect(event.tags.map(\.rawArray) == [["h", "abcdef"], ["previous", "00000001"]])
        #expect(event.content == "hello")
        try event.verify()
    }

    // MARK: Timeline Filters

    @Test("groupTimeline filters on the h tag with the given kinds, since, and limit")
    func groupTimelineFields() {
        let filter = Filter.groupTimeline(
            groupID: "abcdef", kinds: [.chatMessage, .thread], since: Timestamp(rawValue: 1_700_000_000), limit: 20)

        #expect(filter[tag: "h"] == ["abcdef"])
        #expect(filter.kinds == [.chatMessage, .thread])
        #expect(filter.since == Timestamp(rawValue: 1_700_000_000))
        #expect(filter.limit == 20)
    }

    @Test("groupTimeline matches all content kinds by default")
    func groupTimelineDefaults() {
        let filter = Filter.groupTimeline(groupID: "abcdef")

        #expect(filter.kinds == nil)
        #expect(filter.since == nil)
        #expect(filter.limit == nil)
        #expect(filter[tag: "h"] == ["abcdef"])
    }

    @Test("groupTimeline encodes the h tag query under the #h key")
    func groupTimelineEncoding() throws {
        let filter = Filter.groupTimeline(groupID: "abcdef", kinds: [.chatMessage], limit: 10)

        let data = try JSONEncoder().encode(filter)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(object["#h"] as? [String] == ["abcdef"])
        #expect(object["kinds"] as? [Int] == [9])
        #expect(object["limit"] as? Int == 10)
    }

    // MARK: Group Ids

    @Test("groupID reads the h tag of user events")
    func groupIDFromHTag() {
        let event = makeEvent(tags: [Event.Tag(name: "x", values: ["other"]), .group("abcdef")])

        #expect(event.groupID == "abcdef")
    }

    @Test("groupID falls back to the d tag for relay-generated group state")
    func groupIDFromDTag() {
        let state = makeEvent(kind: .groupMetadata, tags: [.identifier("abcdef")])

        #expect(state.groupID == "abcdef")
    }

    @Test("groupID is nil for a d tag outside the relay-state kinds and for no tags")
    func groupIDNilCases() {
        let note = makeEvent(kind: .textNote, tags: [.identifier("abcdef")])

        #expect(note.groupID == nil)
        #expect(makeEvent().groupID == nil)
    }
}

@Suite("NIP-29 Timeline References")
struct NIP29TimelineReferenceTests {

    // MARK: Reference Format

    @Test("previousReference is the first 8 characters of an event id")
    func previousReferenceTruncates() throws {
        let id = try EventID(hex: "f00dbabe" + String(repeating: "0", count: 56))

        #expect(Groups.previousReference(forEventID: id) == "f00dbabe")
    }

    // MARK: Sampling

    @Test("references are sampled only from the newest 50 events")
    func referencesRespectTheWindow() {
        var generator = SeededGenerator(seed: 1)

        let references = Groups.previousReferences(
            from: timelineFixture().shuffled(), maximumCount: 50, using: &generator)

        #expect(references.count == 50)
        #expect(Set(references) == Set((10..<60).map(reference)))
    }

    @Test("the excluded author's events are dropped after windowing, not backfilled")
    func excludesAuthorWithinTheWindow() {
        var generator = SeededGenerator(seed: 2)

        let references = Groups.previousReferences(
            from: timelineFixture(), excludingAuthor: PublicKey.fixture("author-even"), maximumCount: 50,
            using: &generator)

        // The window is indices 10-59; only the 25 odd-authored events remain, and the
        // even-authored slots are not backfilled with older events.
        #expect(references.count == 25)
        #expect(Set(references) == Set((10..<60).filter { !$0.isMultiple(of: 2) }.map(reference)))
    }

    @Test("returns min(maximumCount, available) references and clamps maximumCount to zero")
    func maximumCountClamping() {
        var generator = SeededGenerator(seed: 3)
        let events = timelineFixture()

        #expect(Groups.previousReferences(from: events, maximumCount: 3, using: &generator).count == 3)
        #expect(Groups.previousReferences(from: events, maximumCount: 100, using: &generator).count == 50)
        #expect(Groups.previousReferences(from: events, maximumCount: 0, using: &generator).isEmpty)
        #expect(Groups.previousReferences(from: events, maximumCount: -1, using: &generator).isEmpty)
        #expect(Groups.previousReferences(from: [Event](), using: &generator).isEmpty)
    }

    @Test("sampling is deterministic for a seeded generator")
    func deterministicSampling() {
        var generator = SeededGenerator(seed: 42)

        let references = Groups.previousReferences(from: timelineFixture(), using: &generator)

        #expect(references == ["0000001f", "0000002f", "00000026"])
    }

    @Test("a single call yields distinct references")
    func distinctReferences() {
        var generator = SeededGenerator(seed: 4)

        let references = Groups.previousReferences(
            from: timelineFixture(), maximumCount: 10, using: &generator)

        #expect(references.count == 10)
        #expect(Set(references).count == references.count)
    }

    @Test("timestamp ties are broken by id so the window is deterministic")
    func timestampTiesBreakByID() {
        let events = (0..<51).map { makeEvent(id: paddedID($0)) }
        var generator = SeededGenerator(seed: 5)

        let references = Groups.previousReferences(
            from: events.reversed(), maximumCount: 51, using: &generator)

        #expect(Set(references) == Set((0..<50).map(reference)))
    }

    @Test("the system-randomness overload samples from the same window")
    func systemRandomnessOverload() {
        let references = Groups.previousReferences(
            from: timelineFixture(), excludingAuthor: PublicKey.fixture("author-even"))

        #expect(references.count == 3)
        #expect(Set(references).count == 3)
        #expect(
            Set(references)
                .isSubset(of: Set((10..<60).filter { !$0.isMultiple(of: 2) }.map(reference))))
    }

    // MARK: Verification

    @Test("previousReferences(of:) reads the previous tag")
    func previousReferencesOfEvent() {
        let event = makeEvent(tags: [.group("abcdef"), Event.Tag(name: .previous, values: ["00000001", "00000002"])])

        #expect(Groups.previousReferences(of: event) == ["00000001", "00000002"])
        #expect(Groups.previousReferences(of: makeEvent()) == [])
    }

    @Test("references matching known ids by 8-character prefix are not unknown")
    func allReferencesKnown() {
        let known = [paddedID(1), paddedID(2), paddedID(3)]
        let event = makeEvent(tags: [Event.Tag(name: .previous, values: [reference(1), reference(3)])])

        #expect(Groups.unknownPreviousReferences(of: event, knownEventIDs: known).isEmpty)
    }

    @Test("forged or wrong-length references are reported unknown")
    func unknownReferencesReported() {
        let known = [paddedID(1), paddedID(2)]
        let forged = "deadbeef"
        let wrongLength = String(reference(1).prefix(4))
        let event = makeEvent(tags: [Event.Tag(name: .previous, values: [reference(1), forged, wrongLength])])

        #expect(
            Groups.unknownPreviousReferences(of: event, knownEventIDs: known)
                == [forged, wrongLength])
    }
}
