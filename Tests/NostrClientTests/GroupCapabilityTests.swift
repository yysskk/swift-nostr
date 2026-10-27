import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrGroupManaging`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows the exact
/// NIP-29 template each write builds and what every short form forwards — group, author, timeout,
/// kinds, since, limit, strategy, and the defaults — without a relay.
@Suite("Group Capability Tests")
struct GroupCapabilityTests {
    private let group = GroupReference(relayURL: RelayURL("wss://groups.example.com")!, id: "pizza")
    private let invited = GroupReference(
        relayURL: RelayURL("wss://groups.example.com")!, id: "pizza", inviteCode: "from-link")
    private let signer: EventSigner

    init() throws {
        signer = EventSigner(keyPair: KeyPair())
    }

    private func makeStub() -> RecordingGroupCapabilities {
        RecordingGroupCapabilities(signer: signer)
    }

    /// The one publish the stub recorded.
    private func onlyPublish(_ stub: RecordingGroupCapabilities) async throws -> RecordingGroupCapabilities.Publish {
        let publishes = await stub.publishes
        #expect(publishes.count == 1)
        return try #require(publishes.first)
    }

    // MARK: - Publish primitive's short form

    @Test("publish(_:in:) forwards the template and group with no strategy")
    func publishShortForm() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let template = EventTemplate(kind: .chatMessage, tags: [.group("pizza")], content: "hi")

        let published = try await groups.publish(template, in: group)

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template == template)
        #expect(recorded.group == group)
        #expect(recorded.strategy == nil)
        #expect(published.event.content == "hi")
    }

    // MARK: - Write conveniences

    @Test("join publishes a kind-9021 request carrying the reference's invite code by default")
    func joinDefaults() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.join(invited)

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template.kind == .groupJoinRequest)
        #expect(recorded.template.tags.map(\.rawArray) == [["h", "pizza"], ["code", "from-link"]])
        #expect(recorded.template.content == "")
        #expect(recorded.group == invited)
        #expect(recorded.strategy == nil)
    }

    @Test("join with an invite code overrides the reference's, and forwards the reason and strategy")
    func joinForwardsEverything() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.join(invited, inviteCode: "fresh", reason: "let me in", strategy: .firstAck)

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template.tags.map(\.rawArray) == [["h", "pizza"], ["code", "fresh"]])
        #expect(recorded.template.content == "let me in")
        #expect(recorded.strategy == .firstAck)
    }

    @Test("join without any invite code carries only the h tag")
    func joinWithoutInviteCode() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.join(group)

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template.tags.map(\.rawArray) == [["h", "pizza"]])
    }

    @Test("leave publishes a kind-9022 request with the h tag and the reason")
    func leave() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.leave(group)
        try await groups.leave(group, reason: "bye", strategy: .allSettled)

        let publishes = await stub.publishes
        #expect(publishes.map(\.template.kind) == [.groupLeaveRequest, .groupLeaveRequest])
        #expect(publishes.map { $0.template.tags.map(\.rawArray) } == [[["h", "pizza"]], [["h", "pizza"]]])
        #expect(publishes.map(\.template.content) == ["", "bye"])
        #expect(publishes.map(\.strategy) == [nil, .allSettled])
    }

    @Test("publishMessage defaults to a kind-9 chat message carrying only the h tag")
    func publishMessageDefaults() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.publishMessage("gm", in: group)

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template.kind == .chatMessage)
        #expect(recorded.template.tags.map(\.rawArray) == [["h", "pizza"]])
        #expect(recorded.template.content == "gm")
        #expect(recorded.strategy == nil)
    }

    @Test("publishMessage puts h first, the given tags next, and previous last")
    func publishMessageForwardsEverything() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub

        try await groups.publishMessage(
            "a thread", kind: .thread, in: group, tags: [Tag(name: "title", values: ["Toppings"])],
            previous: ["abcd1234", "ef567890"], strategy: .quorum(1))

        let recorded = try await onlyPublish(stub)
        #expect(recorded.template.kind == .thread)
        #expect(
            recorded.template.tags.map(\.rawArray) == [
                ["h", "pizza"], ["title", "Toppings"], ["previous", "abcd1234", "ef567890"],
            ])
        #expect(recorded.strategy == .quorum(1))
    }

    @Test("publishModeration builds the action's kind and tags, then previous, with the reason as content")
    func publishModeration() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let member = PublicKey.fixture("member")

        try await groups.publishModeration(.createGroup, in: group)
        try await groups.publishModeration(
            .putUser(publicKey: member, roles: ["moderator"]), in: group, previous: ["abcd1234"],
            reason: "promoted", strategy: .firstAck)

        let publishes = await stub.publishes
        #expect(publishes.map(\.template.kind) == [.groupCreation, .groupPutUser])
        #expect(
            publishes.map { $0.template.tags.map(\.rawArray) } == [
                [["h", "pizza"]],
                [["h", "pizza"], ["p", member.hex, "moderator"], ["previous", "abcd1234"]],
            ])
        #expect(publishes.map(\.template.content) == ["", "promoted"])
        #expect(publishes.map(\.strategy) == [nil, .firstAck])
    }

    // MARK: - Read short forms

    @Test("fetchMetadata and fetchState forward the author, nil by default, and no timeout")
    func stateFetchShortForms() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let relayKey = PublicKey.fixture("relay")

        _ = try await groups.fetchMetadata(for: group)
        _ = try await groups.fetchMetadata(for: group, authorPublicKey: relayKey)
        _ = try await groups.fetchState(for: group)
        _ = try await groups.fetchState(for: group, authorPublicKey: relayKey)

        #expect(
            await stub.metadataFetches == [
                .init(group: group, authorPublicKey: nil, timeout: nil),
                .init(group: group, authorPublicKey: relayKey, timeout: nil),
            ])
        #expect(
            await stub.stateFetches == [
                .init(group: group, authorPublicKey: nil, timeout: nil),
                .init(group: group, authorPublicKey: relayKey, timeout: nil),
            ])
    }

    @Test("subscribe(to:) forwards one group-timeline filter of only what it is given")
    func subscribeShortForm() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let since = Timestamp(rawValue: 1_700_000_000)

        _ = try await groups.subscribe(to: group)
        _ = try await groups.subscribe(to: group, kinds: [.chatMessage])
        _ = try await groups.subscribe(to: group, kinds: [.thread], since: since, limit: 10)
        _ = try await groups.subscribe(to: group, since: since)
        _ = try await groups.subscribe(to: group, limit: 50)

        #expect(
            await stub.subscribes == [
                .init(group: group, filters: [.groupTimeline(groupID: group.id)]),
                .init(group: group, filters: [.groupTimeline(groupID: group.id, kinds: [.chatMessage])]),
                .init(
                    group: group,
                    filters: [.groupTimeline(groupID: group.id, kinds: [.thread], since: since, limit: 10)]),
                .init(group: group, filters: [.groupTimeline(groupID: group.id, since: since)]),
                .init(group: group, filters: [.groupTimeline(groupID: group.id, limit: 50)]),
            ])
    }

    @Test("fetchSimpleGroupList asks for the current user's list, or the given author's, with no timeout")
    func fetchSimpleGroupListShortForm() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let other = PublicKey.fixture("other")

        _ = try await groups.fetchSimpleGroupList()
        _ = try await groups.fetchSimpleGroupList(for: other)

        #expect(
            await stub.listFetches == [
                .init(publicKey: nil, timeout: nil),
                .init(publicKey: other, timeout: nil),
            ])
    }

    @Test("publishSimpleGroupList(_:) forwards the list with no strategy")
    func publishSimpleGroupListShortForm() async throws {
        let stub = makeStub()
        let groups: any NostrGroupManaging = stub
        let list = SimpleGroupList(publicEntries: [GroupListEntry(group)])

        let published = try await groups.publishSimpleGroupList(list)

        let recorded = await stub.listPublishes
        #expect(recorded.map(\.list) == [list])
        #expect(recorded.map(\.strategy) == [nil])
        #expect(published.event.kind == .simpleGroupList)
    }
}
