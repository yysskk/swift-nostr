import Foundation
import NostrCore
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
    id: String = String(repeating: "a", count: 64),
    pubkey: String = "pk",
    createdAt: Int64 = 1_700_000_000,
    kind: Event.Kind = .chatMessage,
    tags: [[String]] = []
) -> Event {
    Event(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: "", sig: "sig")
}

/// The 64-character event id whose first 8 characters encode `index` in hex.
private func paddedID(_ index: Int) -> String {
    String(format: "%08x", index) + String(repeating: "0", count: 56)
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
            pubkey: index.isMultiple(of: 2) ? "author-even" : "author-odd",
            createdAt: 1_700_000_000 + Int64(index)
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
            Event.Tag.simpleGroup(id: "abcdef", relayURL: "wss://groups.example.com").rawArray
                == ["group", "abcdef", "wss://groups.example.com"])
        #expect(
            Event.Tag.simpleGroup(id: "abcdef", relayURL: "wss://groups.example.com", name: "Cooking").rawArray
                == ["group", "abcdef", "wss://groups.example.com", "Cooking"])
    }

    @Test("a p tag with roles appends them after the pubkey")
    func pubkeyRolesTag() {
        let pk = String(repeating: "b", count: 64)
        #expect(Event.Tag.pubkey(pk, roles: ["admin", "moderator"]).rawArray == ["p", pk, "admin", "moderator"])
        #expect(Event.Tag.pubkey(pk, roles: []).rawArray == ["p", pk])
    }
}

@Suite("NIP-29 Group Event Builders")
struct NIP29GroupEventBuilderTests {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Join Requests

    @Test("an unsigned join request carries the h tag first, then the invite code")
    func unsignedJoinRequest() {
        let unsigned = Groups.joinRequest(
            groupID: "abcdef",
            inviteCode: "invite123",
            reason: "let me in",
            pubkey: "author",
            createdAt: createdAt
        )

        #expect(unsigned.kind == .groupJoinRequest)
        #expect(unsigned.pubkey == "author")
        #expect(unsigned.createdAt == 1_700_000_000)
        #expect(unsigned.tags == [["h", "abcdef"], ["code", "invite123"]])
        #expect(unsigned.content == "let me in")
    }

    @Test("a join request without an invite code or reason has one tag and empty content")
    func unsignedJoinRequestDefaults() {
        let unsigned = Groups.joinRequest(groupID: "abcdef", pubkey: "author")

        #expect(unsigned.tags == [["h", "abcdef"]])
        #expect(unsigned.content.isEmpty)
    }

    @Test("a signed join request verifies and keeps the unsigned layout")
    func signedJoinRequest() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await Groups.joinRequest(
            groupID: "abcdef",
            inviteCode: "invite123",
            reason: "let me in",
            createdAt: createdAt,
            signer: signer
        )

        #expect(event.kind == .groupJoinRequest)
        #expect(event.pubkey == signer.publicKey)
        #expect(event.createdAt == 1_700_000_000)
        #expect(event.tags == [["h", "abcdef"], ["code", "invite123"]])
        #expect(event.content == "let me in")
        #expect(try event.verify())
    }

    // MARK: Leave Requests

    @Test("an unsigned leave request carries only the h tag")
    func unsignedLeaveRequest() {
        let unsigned = Groups.leaveRequest(
            groupID: "abcdef",
            reason: "goodbye",
            pubkey: "author",
            createdAt: createdAt
        )

        #expect(unsigned.kind == .groupLeaveRequest)
        #expect(unsigned.pubkey == "author")
        #expect(unsigned.createdAt == 1_700_000_000)
        #expect(unsigned.tags == [["h", "abcdef"]])
        #expect(unsigned.content == "goodbye")
        #expect(Groups.leaveRequest(groupID: "abcdef", pubkey: "author").content.isEmpty)
    }

    @Test("a signed leave request verifies with kind 9022 and never carries a code tag")
    func signedLeaveRequest() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await Groups.leaveRequest(groupID: "abcdef", createdAt: createdAt, signer: signer)

        #expect(event.kind == .groupLeaveRequest)
        #expect(event.pubkey == signer.publicKey)
        #expect(event.tags == [["h", "abcdef"]])
        #expect(event.content.isEmpty)
        #expect(try event.verify())
    }

    // MARK: Group-Scoped Content

    @Test("contentEvent puts the h tag first, then custom tags in order, then previous")
    func contentEventTagOrder() {
        let unsigned = Groups.contentEvent(
            groupID: "abcdef",
            kind: .chatMessage,
            content: "hello",
            tags: [.hashtag("nostr"), .pubkey("pk1")],
            previous: ["00000001", "00000002"],
            pubkey: "author",
            createdAt: createdAt
        )

        #expect(unsigned.kind == .chatMessage)
        #expect(unsigned.content == "hello")
        #expect(
            unsigned.tags == [
                ["h", "abcdef"],
                ["t", "nostr"],
                ["p", "pk1"],
                ["previous", "00000001", "00000002"],
            ])
    }

    @Test("contentEvent omits the previous tag when no references are given")
    func contentEventWithoutPrevious() {
        let unsigned = Groups.contentEvent(
            groupID: "abcdef", kind: .chatMessage, content: "hello", pubkey: "author")

        #expect(unsigned.tags == [["h", "abcdef"]])
    }

    @Test("contentEvent honors arbitrary content kinds")
    func contentEventArbitraryKind() {
        let article = Groups.contentEvent(
            groupID: "abcdef", kind: Event.Kind(rawValue: 30023), content: "post", pubkey: "author")

        #expect(article.kind.rawValue == 30023)
        #expect(article.tags.first == ["h", "abcdef"])
    }

    @Test("a signed content event verifies and keeps the unsigned layout")
    func signedContentEvent() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await Groups.contentEvent(
            groupID: "abcdef",
            kind: .chatMessage,
            content: "hello",
            createdAt: createdAt,
            signer: signer
        )

        #expect(event.kind == .chatMessage)
        #expect(event.pubkey == signer.publicKey)
        #expect(event.createdAt == 1_700_000_000)
        #expect(event.tags == [["h", "abcdef"]])
        #expect(event.content == "hello")
        #expect(try event.verify())
    }

    // MARK: Timeline Filters

    @Test("groupTimeline filters on the h tag with the given kinds, since, and limit")
    func groupTimelineFields() {
        let filter = Filter.groupTimeline(
            groupID: "abcdef", kinds: [.chatMessage, .thread], since: 1_700_000_000, limit: 20)

        #expect(filter.tagQuery("h") == ["abcdef"])
        #expect(filter.kinds == [.chatMessage, .thread])
        #expect(filter.since == 1_700_000_000)
        #expect(filter.limit == 20)
    }

    @Test("groupTimeline matches all content kinds by default")
    func groupTimelineDefaults() {
        let filter = Filter.groupTimeline(groupID: "abcdef")

        #expect(filter.kinds == nil)
        #expect(filter.since == nil)
        #expect(filter.limit == nil)
        #expect(filter.tagQuery("h") == ["abcdef"])
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
        let event = makeEvent(tags: [["x", "other"], ["h", "abcdef"]])

        #expect(event.groupID == "abcdef")
    }

    @Test("groupID falls back to the d tag for relay-generated group state")
    func groupIDFromDTag() {
        let state = makeEvent(kind: .groupMetadata, tags: [["d", "abcdef"]])

        #expect(state.groupID == "abcdef")
    }

    @Test("groupID is nil for a d tag outside the relay-state kinds and for no tags")
    func groupIDNilCases() {
        let note = makeEvent(kind: .textNote, tags: [["d", "abcdef"]])

        #expect(note.groupID == nil)
        #expect(makeEvent().groupID == nil)
    }
}

@Suite("NIP-29 Timeline References")
struct NIP29TimelineReferenceTests {

    // MARK: Reference Format

    @Test("previousReference is the first 8 characters of an event id")
    func previousReferenceTruncates() {
        let id = "f00dbabe" + String(repeating: "0", count: 56)

        #expect(Groups.previousReference(forEventID: id) == "f00dbabe")
        #expect(Groups.previousReference(forEventID: "abc") == "abc")
    }

    // MARK: Sampling

    @Test("references are sampled only from the newest 50 events")
    func referencesRespectTheWindow() {
        var generator = SeededGenerator(seed: 1)

        let references = Groups.previousReferences(
            from: timelineFixture().shuffled(), maxCount: 50, using: &generator)

        #expect(references.count == 50)
        #expect(Set(references) == Set((10..<60).map(reference)))
    }

    @Test("the excluded author's events are dropped after windowing, not backfilled")
    func excludesAuthorWithinTheWindow() {
        var generator = SeededGenerator(seed: 2)

        let references = Groups.previousReferences(
            from: timelineFixture(), excludingAuthor: "author-even", maxCount: 50, using: &generator)

        // The window is indices 10-59; only the 25 odd-authored events remain, and the
        // even-authored slots are not backfilled with older events.
        #expect(references.count == 25)
        #expect(Set(references) == Set((10..<60).filter { !$0.isMultiple(of: 2) }.map(reference)))
    }

    @Test("returns min(maxCount, available) references and clamps maxCount to zero")
    func maxCountClamping() {
        var generator = SeededGenerator(seed: 3)
        let events = timelineFixture()

        #expect(Groups.previousReferences(from: events, maxCount: 3, using: &generator).count == 3)
        #expect(Groups.previousReferences(from: events, maxCount: 100, using: &generator).count == 50)
        #expect(Groups.previousReferences(from: events, maxCount: 0, using: &generator).isEmpty)
        #expect(Groups.previousReferences(from: events, maxCount: -1, using: &generator).isEmpty)
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
            from: timelineFixture(), maxCount: 10, using: &generator)

        #expect(references.count == 10)
        #expect(Set(references).count == references.count)
    }

    @Test("timestamp ties are broken by id so the window is deterministic")
    func timestampTiesBreakById() {
        let events = (0..<51).map { makeEvent(id: paddedID($0)) }
        var generator = SeededGenerator(seed: 5)

        let references = Groups.previousReferences(
            from: events.reversed(), maxCount: 51, using: &generator)

        #expect(Set(references) == Set((0..<50).map(reference)))
    }

    @Test("the system-randomness overload samples from the same window")
    func systemRandomnessOverload() {
        let references = Groups.previousReferences(
            from: timelineFixture(), excludingAuthor: "author-even")

        #expect(references.count == 3)
        #expect(Set(references).count == 3)
        #expect(
            Set(references)
                .isSubset(of: Set((10..<60).filter { !$0.isMultiple(of: 2) }.map(reference))))
    }

    // MARK: Verification

    @Test("previousReferences(of:) reads the previous tag")
    func previousReferencesOfEvent() {
        let event = makeEvent(tags: [["h", "abcdef"], ["previous", "00000001", "00000002"]])

        #expect(Groups.previousReferences(of: event) == ["00000001", "00000002"])
        #expect(Groups.previousReferences(of: makeEvent()) == [])
    }

    @Test("references matching known ids by 8-character prefix are not unknown")
    func allReferencesKnown() {
        let known = [paddedID(1), paddedID(2), paddedID(3)]
        let event = makeEvent(tags: [["previous", reference(1), reference(3)]])

        #expect(Groups.unknownPreviousReferences(of: event, knownEventIDs: known).isEmpty)
    }

    @Test("forged or wrong-length references are reported unknown")
    func unknownReferencesReported() {
        let known = [paddedID(1), paddedID(2)]
        let forged = "deadbeef"
        let wrongLength = String(reference(1).prefix(4))
        let event = makeEvent(tags: [["previous", reference(1), forged, wrongLength]])

        #expect(
            Groups.unknownPreviousReferences(of: event, knownEventIDs: known)
                == [forged, wrongLength])
    }
}
