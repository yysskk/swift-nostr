import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A ``NostrSigning`` that signs with a held key but is not an ``EventSigner`` — it stands in
/// for a remote NIP-46 signer so the group flows' signing seam can be exercised end to end.
private struct FakeRemoteSigner: NostrSigning {
    let keyPair: KeyPair

    var publicKey: String {
        get async throws { keyPair.publicKeyHex }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        try EventSigner(keyPair: keyPair).sign(event)
    }

    func nip44Encrypt(_ plaintext: String, to recipientPubkey: String) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Encrypt(plaintext, to: recipientPubkey)
    }

    func nip44Decrypt(_ ciphertext: String, from senderPubkey: String) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Decrypt(ciphertext, from: senderPubkey)
    }
}

@Suite("NIP-29 Group Client Tests")
struct NIP29GroupClientTests {

    private let groupRelayURL = URL(string: "wss://groups.example.com")!
    private let otherRelayURL = URL(string: "wss://other.example.com")!
    private let groupID = "abcdef"

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    /// Builds a client whose relays all speak to one test-controlled socket.
    private func makeClient() -> (NostrClient, MockWebSocketSession) {
        let socket = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket })
        )
        return (NostrClient(relayPool: pool), socket)
    }

    /// Builds a client whose factory hands out `first`, then `second`; connect relays
    /// sequentially so each pairs with a known socket.
    private func makeTwoSocketClient() -> (NostrClient, MockWebSocketSession, MockWebSocketSession) {
        let first = MockWebSocketSession()
        let second = MockWebSocketSession()
        let sockets = [first, second]
        let counter = SessionCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets[counter.next()] })
        )
        return (NostrClient(relayPool: pool), first, second)
    }

    // MARK: - Frame helpers

    private func hasEventFrame(_ socket: MockWebSocketSession) -> Bool {
        socket.sentTextFrames.contains { $0.hasPrefix("[\"EVENT\"") }
    }

    /// Extracts the subscription id and first filter of the first REQ frame sent on `socket`.
    private func sentREQ(in socket: MockWebSocketSession) throws -> (subscriptionId: String, filter: [String: Any]) {
        guard let frame = socket.sentTextFrames.first(where: { $0.hasPrefix("[\"REQ\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 3,
            let subscriptionId = array[1] as? String,
            let filter = array[2] as? [String: Any]
        else {
            throw NostrError.invalidMessageFormat
        }
        return (subscriptionId, filter)
    }

    /// Waits for the next EVENT frame on `socket`, delivers the relay's OK for it, and
    /// returns the sent event.
    @discardableResult
    private func acknowledgePublish(on socket: MockWebSocketSession) async throws -> Event {
        try await PublishAckSupport.acknowledgePublish(on: socket)
    }

    /// A canned `["EVENT", subscriptionId, {...}]` relay frame for `event`.
    private func eventFrame(subscriptionId: String, event: Event) throws -> String {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        return "[\"EVENT\",\"\(subscriptionId)\",\(json)]"
    }

    /// Builds and signs a relay-generated kind-39xxx state event at a pinned timestamp.
    private func stateEvent(
        kind: Event.Kind,
        fieldTags: [Event.Tag],
        createdAt: Int64,
        signer: EventSigner
    ) throws -> Event {
        try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey,
                createdAt: createdAt,
                kind: kind,
                tags: [.identifier(groupID)] + fieldTags,
                content: ""
            )
        )
    }

    /// Runs `fetch` while answering the socket's REQ with the canned `events` and an EOSE.
    private func answering<T: Sendable>(
        _ socket: MockWebSocketSession,
        with events: [Event],
        during fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await fetch() }
        try await NIP42TestSupport.pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let (subscriptionId, _) = try sentREQ(in: socket)
        for event in events {
            socket.deliver(.string(try eventFrame(subscriptionId: subscriptionId, event: event)))
        }
        socket.deliver(.string("[\"EOSE\",\"\(subscriptionId)\"]"))
        return try await task.value
    }

    // MARK: - Publishing flows

    @Test("groups.join publishes a kind-9021 event only to the group's relay")
    func joinGroupTargetsOnlyTheGroupRelay() async throws {
        let (client, groupSocket, otherSocket) = makeTwoSocketClient()
        let groupConnection = try await client.relays.pool.addRelay(groupRelayURL)
        try await groupConnection.connect()
        let otherConnection = try await client.relays.pool.addRelay(otherRelayURL)
        try await otherConnection.connect()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID, inviteCode: "welcome")
        let joinTask = Task { try await client.groups.join(group, reason: "please let me in") }
        let sent = try await acknowledgePublish(on: groupSocket)
        let published = try await joinTask.value

        #expect(sent.kind == .groupJoinRequest)
        #expect(sent.structuredTags.first == .group(groupID))
        #expect(sent.firstTagValue(named: "code") == "welcome")
        #expect(sent.content == "please let me in")
        #expect(try sent.verify())
        #expect(published.event == sent)
        #expect(published.result.acceptedRelays == [groupRelayURL])
        #expect(!hasEventFrame(otherSocket))
        await client.relays.disconnect()
    }

    @Test("an explicit invite code overrides the reference's code")
    func joinGroupInviteCodeOverride() async throws {
        let (client, socket) = makeClient()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.relays.connect(to: [groupRelayURL.absoluteString])

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID, inviteCode: "stale")
        let joinTask = Task { try await client.groups.join(group, inviteCode: "fresh") }
        let sent = try await acknowledgePublish(on: socket)
        _ = try await joinTask.value

        #expect(sent.firstTagValue(named: "code") == "fresh")
        await client.relays.disconnect()
    }

    @Test("groups.leave publishes a kind-9022 event with the h tag")
    func leaveGroupPublishesLeaveRequest() async throws {
        let (client, socket) = makeClient()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.relays.connect(to: [groupRelayURL.absoluteString])

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let leaveTask = Task { try await client.groups.leave(group, reason: "goodbye") }
        let sent = try await acknowledgePublish(on: socket)
        _ = try await leaveTask.value

        #expect(sent.kind == .groupLeaveRequest)
        #expect(sent.structuredTags == [.group(groupID)])
        #expect(sent.content == "goodbye")
        #expect(try sent.verify())
        await client.relays.disconnect()
    }

    @Test("groups.publishMessage defaults to kind 9 with h first and previous last")
    func publishGroupMessageLayout() async throws {
        let (client, socket) = makeClient()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.relays.connect(to: [groupRelayURL.absoluteString])

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let publishTask = Task {
            try await client.groups.publishMessage(
                "hello group",
                in: group,
                tags: [.hashtag("intro")],
                previous: ["deadbeef", "cafebabe"]
            )
        }
        let sent = try await acknowledgePublish(on: socket)
        _ = try await publishTask.value

        #expect(sent.kind == .chatMessage)
        #expect(sent.structuredTags == [.group(groupID), .hashtag("intro"), .previous(["deadbeef", "cafebabe"])])
        #expect(sent.content == "hello group")
        await client.relays.disconnect()
    }

    @Test("groups.publishModeration putUser publishes kind 9000 with the roled p tag")
    func publishGroupModerationPutUser() async throws {
        let (client, socket) = makeClient()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.relays.connect(to: [groupRelayURL.absoluteString])
        let member = try KeyPair().publicKeyHex

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let moderationTask = Task {
            try await client.groups.publishModeration(
                .putUser(pubkey: member, roles: ["moderator"]),
                in: group,
                reason: "promoting"
            )
        }
        let sent = try await acknowledgePublish(on: socket)
        _ = try await moderationTask.value

        #expect(sent.kind == .groupPutUser)
        #expect(sent.structuredTags == [.group(groupID), .pubkey(member, roles: ["moderator"])])
        #expect(sent.content == "promoting")
        await client.relays.disconnect()
    }

    @Test("a group relay missing from the pool is added and connected automatically")
    func ensureGroupRelayAddsAndConnects() async throws {
        let (client, socket) = makeClient()
        await client.identity.setSigner(EventSigner(keyPair: try KeyPair()))
        #expect(await client.relays.pool.relay(for: groupRelayURL) == nil)

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let publishTask = Task { try await client.groups.publishMessage("first post", in: group) }
        let sent = try await acknowledgePublish(on: socket)
        let published = try await publishTask.value

        #expect(sent.kind == .chatMessage)
        #expect(published.result.acceptedRelays == [groupRelayURL])
        let connection = try #require(await client.relays.pool.relay(for: groupRelayURL))
        #expect(await connection.state == .connected)
        await client.relays.disconnect()
    }

    @Test("groups.join signs through a remote NostrSigning signer")
    func joinGroupWithRemoteSigner() async throws {
        let (client, socket) = makeClient()
        let keyPair = try KeyPair()
        try await client.identity.setSigner(FakeRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID, inviteCode: "welcome")
        let joinTask = Task { try await client.groups.join(group) }
        let sent = try await acknowledgePublish(on: socket)
        _ = try await joinTask.value

        #expect(sent.kind == .groupJoinRequest)
        #expect(sent.pubkey == keyPair.publicKeyHex)
        #expect(sent.firstTagValue(named: "code") == "welcome")
        #expect(try sent.verify())
        await client.relays.disconnect()
    }

    // MARK: - State fetches

    @Test("groups.fetchMetadata keeps the newest copy across stale ones")
    func fetchGroupMetadataNewestWins() async throws {
        let (client, socket) = makeClient()
        try await client.relays.connect(to: [groupRelayURL.absoluteString])
        let relaySigner = EventSigner(keyPair: try KeyPair())
        let stale = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Old"])],
            createdAt: 1_700_000_000, signer: relaySigner)
        let newer = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["New"])],
            createdAt: 1_700_000_100, signer: relaySigner)

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let metadata = try await answering(socket, with: [stale, newer]) {
            try await client.groups.fetchMetadata(for: group)
        }

        #expect(metadata?.groupID == groupID)
        #expect(metadata?.name == "New")

        let (_, filter) = try sentREQ(in: socket)
        #expect(filter["#d"] as? [String] == [groupID])
        #expect(filter["kinds"] as? [Int] == [39000])
        await client.relays.disconnect()
    }

    @Test("with the relay pubkey known, an impostor's newer metadata is dropped")
    func fetchGroupMetadataDropsImpostor() async throws {
        let relaySigner = EventSigner(keyPair: try KeyPair())
        let impostorSigner = EventSigner(keyPair: try KeyPair())
        let genuine = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Genuine"])],
            createdAt: 1_700_000_000, signer: relaySigner)
        let impostor = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Impostor"])],
            createdAt: 1_700_000_100, signer: impostorSigner)

        // The expected author carried by the reference itself.
        let (client, socket) = makeClient()
        try await client.relays.connect(to: [groupRelayURL.absoluteString])
        let viaReference = GroupReference(
            relayURL: groupRelayURL.absoluteString, id: groupID, relayPubkey: relaySigner.publicKey)
        let metadata = try await answering(socket, with: [genuine, impostor]) {
            try await client.groups.fetchMetadata(for: viaReference)
        }
        #expect(metadata?.name == "Genuine")
        await client.relays.disconnect()

        // The explicit authorPubkey parameter, with a reference that carries no pubkey.
        let (parameterClient, parameterSocket) = makeClient()
        try await parameterClient.relays.connect(to: [groupRelayURL.absoluteString])
        let bare = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let parameterMetadata = try await answering(parameterSocket, with: [genuine, impostor]) {
            try await parameterClient.groups.fetchMetadata(for: bare, authorPubkey: relaySigner.publicKey)
        }
        #expect(parameterMetadata?.name == "Genuine")
        await parameterClient.relays.disconnect()
    }

    @Test("without an expected author, the newest metadata wins regardless of its author")
    func fetchGroupMetadataWithoutValidationTrustsTheRelay() async throws {
        let (client, socket) = makeClient()
        try await client.relays.connect(to: [groupRelayURL.absoluteString])
        let relaySigner = EventSigner(keyPair: try KeyPair())
        let impostorSigner = EventSigner(keyPair: try KeyPair())
        let genuine = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Genuine"])],
            createdAt: 1_700_000_000, signer: relaySigner)
        let impostor = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Impostor"])],
            createdAt: 1_700_000_100, signer: impostorSigner)

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let metadata = try await answering(socket, with: [genuine, impostor]) {
            try await client.groups.fetchMetadata(for: group)
        }

        #expect(metadata?.name == "Impostor")
        await client.relays.disconnect()
    }

    @Test("groups.fetchState fills the fetched kinds and leaves the rest nil")
    func fetchGroupStateSnapshot() async throws {
        let (client, socket) = makeClient()
        try await client.relays.connect(to: [groupRelayURL.absoluteString])
        let relaySigner = EventSigner(keyPair: try KeyPair())
        let admin = try KeyPair().publicKeyHex
        let metadata = try stateEvent(
            kind: .groupMetadata, fieldTags: [Event.Tag(name: "name", values: ["Pizza Lovers"])],
            createdAt: 1_700_000_000, signer: relaySigner)
        let admins = try stateEvent(
            kind: .groupAdmins, fieldTags: [.pubkey(admin, roles: ["ceo"])],
            createdAt: 1_700_000_001, signer: relaySigner)
        let roles = try stateEvent(
            kind: .groupRoles, fieldTags: [.role("ceo", description: "the boss")],
            createdAt: 1_700_000_002, signer: relaySigner)

        let group = GroupReference(
            relayURL: groupRelayURL.absoluteString, id: groupID, relayPubkey: relaySigner.publicKey)
        let state = try await answering(socket, with: [metadata, admins, roles]) {
            try await client.groups.fetchState(for: group)
        }

        #expect(state.metadata?.name == "Pizza Lovers")
        #expect(state.admins?.admins == [Groups.Admin(pubkey: admin, roles: ["ceo"])])
        #expect(state.roles?.roles == [Groups.Role(name: "ceo", description: "the boss")])
        #expect(state.members == nil)
        #expect(state.pins == nil)

        let (_, filter) = try sentREQ(in: socket)
        #expect(filter["#d"] as? [String] == [groupID])
        #expect(filter["kinds"] as? [Int] == [39000, 39001, 39002, 39003, 39005])
        await client.relays.disconnect()
    }

    // MARK: - Timeline subscription

    @Test("groups.timeline requests the group's #h timeline from its relay")
    func subscribeToGroupTimelineFilter() async throws {
        let (client, socket) = makeClient()

        let group = GroupReference(relayURL: groupRelayURL.absoluteString, id: groupID)
        let subscription = try await client.groups.timeline(
            group,
            kinds: [.chatMessage],
            since: Date(timeIntervalSince1970: 1_700_000_000),
            limit: 50
        )
        try await NIP42TestSupport.pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let (_, filter) = try sentREQ(in: socket)

        #expect(filter["#h"] as? [String] == [groupID])
        #expect(filter["kinds"] as? [Int] == [9])
        #expect(filter["since"] as? Int == 1_700_000_000)
        #expect(filter["limit"] as? Int == 50)
        await subscription.close()
        await client.relays.disconnect()
    }
}

/// Hands out incrementing indexes to a factory closure that must stay `@Sendable`.
private final class SessionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
