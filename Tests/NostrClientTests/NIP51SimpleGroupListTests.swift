import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-51 Simple Group List")
struct NIP51SimpleGroupListTests {

    private let groupID = "abcdef"
    private let groupRelay = "wss://groups.example.com"

    // MARK: - Entry ⇔ tag round-trips

    @Test("An entry without a name produces a two-value group tag")
    func entryTagWithoutName() {
        let entry = GroupListEntry(groupID: groupID, relayURL: groupRelay)
        #expect(entry.tag.rawArray == ["group", groupID, groupRelay])
    }

    @Test("An entry with a name produces a three-value group tag")
    func entryTagWithName() {
        let entry = GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "Cooking")
        #expect(entry.tag.rawArray == ["group", groupID, groupRelay, "Cooking"])
    }

    @Test("A named group tag parses and round-trips")
    func namedTagRoundTrip() throws {
        let tag = Event.Tag.simpleGroup(id: groupID, relayURL: groupRelay, name: "Cooking")
        let entry = try #require(GroupListEntry(tag: tag))
        #expect(entry.groupID == groupID)
        #expect(entry.relayURL == groupRelay)
        #expect(entry.name == "Cooking")
        #expect(entry.tag == tag)
    }

    @Test("A nameless group tag parses with a nil name and round-trips")
    func namelessTagRoundTrip() throws {
        let tag = Event.Tag.simpleGroup(id: groupID, relayURL: groupRelay)
        let entry = try #require(GroupListEntry(tag: tag))
        #expect(entry.name == nil)
        #expect(entry.tag == tag)
    }

    @Test("A present-but-empty name is treated as nil")
    func emptyNameBecomesNil() throws {
        let tag = try #require(Event.Tag.raw(["group", groupID, groupRelay, ""]))
        let entry = try #require(GroupListEntry(tag: tag))
        #expect(entry.name == nil)
        #expect(entry.tag.rawArray == ["group", groupID, groupRelay])
    }

    @Test("An empty name is normalized to nil on construction and mutation")
    func emptyNameNormalizedEverywhere() {
        #expect(GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "").name == nil)

        var entry = GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "Cooking")
        entry.name = ""
        #expect(entry.name == nil)
        #expect(entry.tag.rawArray == ["group", groupID, groupRelay])
        #expect(GroupListEntry(tag: entry.tag) == entry)
    }

    @Test(
        "Out-of-shape tags do not parse as entries",
        arguments: [
            ["community", "abcdef", "wss://groups.example.com"],  // wrong tag name
            ["group", "abcdef"],  // missing relay value
            ["group", "", "wss://groups.example.com"],  // empty id
            ["group", "abcdef", ""],  // empty relay
            ["group", "abcdef", "wss://groups.example.com", "Cooking", "extra"],  // values beyond the name
        ]
    )
    func outOfShapeTagsDoNotParse(rawArray: [String]) throws {
        let tag = try #require(Event.Tag.raw(rawArray))
        #expect(GroupListEntry(tag: tag) == nil)
    }

    // MARK: - GroupReference bridging

    @Test("An entry built from a reference keeps only the list fields")
    func entryFromReference() {
        let reference = GroupReference(
            relayURL: groupRelay, id: groupID, relayPubkey: "aabbcc", inviteCode: "welcome")
        let entry = GroupListEntry(reference, name: "Cooking")
        #expect(entry.groupID == groupID)
        #expect(entry.relayURL == groupRelay)
        #expect(entry.name == "Cooking")
    }

    @Test("An entry's reference carries no relay pubkey or invite code")
    func entryToReference() {
        let entry = GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "Cooking")
        let reference = entry.reference
        #expect(reference.id == groupID)
        #expect(reference.relayURL == groupRelay)
        #expect(reference.relayPubkey == nil)
        #expect(reference.inviteCode == nil)
    }

    // MARK: - Typed view over NostrList

    @Test("The typed view partitions group, r, and other tags in order")
    func typedViewPartitionsTags() throws {
        let unknown = Event.Tag(name: "client", values: ["nostrapp"])
        let malformedGroup = try #require(Event.Tag.raw(["group", ""]))
        let markedRelay = Event.Tag(name: "r", values: ["wss://marked.example.com", "read"])
        let list = NostrList(
            kind: .simpleGroupList,
            publicItems: [
                .simpleGroup(id: groupID, relayURL: groupRelay, name: "Cooking"),
                unknown,
                .reference(groupRelay),
                .simpleGroup(id: "012345", relayURL: "wss://other.example.com"),
                malformedGroup,
                .reference("wss://other.example.com"),
                markedRelay,
            ]
        )

        let typed = try SimpleGroupList(list: list)
        #expect(
            typed.publicEntries == [
                GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "Cooking"),
                GroupListEntry(groupID: "012345", relayURL: "wss://other.example.com"),
            ]
        )
        #expect(typed.relayURLs == [groupRelay, "wss://other.example.com"])
        #expect(typed.additionalPublicTags == [unknown, malformedGroup, markedRelay])
        #expect(typed.privateEntries.isEmpty)
        #expect(typed.additionalPrivateTags.isEmpty)
    }

    @Test("Back-conversion normalizes grouping but preserves every tag's content")
    func backConversionIsContentLossless() throws {
        let malformedGroup = try #require(Event.Tag.raw(["group", "", "wss://broken.example.com"]))
        let original = NostrList(
            kind: .simpleGroupList,
            publicItems: [
                .reference(groupRelay),
                Event.Tag(name: "client", values: ["nostrapp"]),
                .simpleGroup(id: groupID, relayURL: groupRelay, name: "Cooking"),
                malformedGroup,
                .simpleGroup(id: "012345", relayURL: "wss://other.example.com"),
            ],
            privateItems: [
                Event.Tag(name: "note", values: ["remember"]),
                .simpleGroup(id: "5ec4e7", relayURL: "wss://hidden.example.com"),
            ]
        )

        let typed = try SimpleGroupList(list: original)
        let rebuilt = typed.list
        #expect(rebuilt.kind == .simpleGroupList)
        // The documented grouping: entries first, then "r" tags, then the additional tags.
        #expect(
            rebuilt.publicItems == [
                Event.Tag.simpleGroup(id: groupID, relayURL: groupRelay, name: "Cooking"),
                .simpleGroup(id: "012345", relayURL: "wss://other.example.com"),
                .reference(groupRelay),
                Event.Tag(name: "client", values: ["nostrapp"]),
                malformedGroup,
            ]
        )
        #expect(
            rebuilt.privateItems == [
                Event.Tag.simpleGroup(id: "5ec4e7", relayURL: "wss://hidden.example.com"),
                Event.Tag(name: "note", values: ["remember"]),
            ]
        )
        // Content-lossless: the same tags as multisets, and a re-parse yields an equal view.
        #expect(multiset(rebuilt.publicItems) == multiset(original.publicItems))
        #expect(multiset(rebuilt.privateItems) == multiset(original.privateItems))
        #expect(try SimpleGroupList(list: rebuilt) == typed)
    }

    /// The tags as a multiset, for order-insensitive content comparison.
    private func multiset(_ tags: [Event.Tag]) -> [Event.Tag: Int] {
        tags.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    @Test("A list of another kind is rejected")
    func wrongKindRejected() {
        let list = NostrList(kind: .muteList, publicItems: [.word("spam")])
        #expect(throws: NostrError.invalidData) {
            _ = try SimpleGroupList(list: list)
        }
    }

    // MARK: - Private entries through signList/openList

    @Test("Private entries and additional private tags survive sign and open")
    func privateEntriesRoundTrip() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let typed = SimpleGroupList(
            publicEntries: [GroupListEntry(groupID: groupID, relayURL: groupRelay)],
            privateEntries: [
                GroupListEntry(groupID: "secret-group-id", relayURL: "wss://hidden.example.com", name: "Secret Kitchen")
            ],
            relayURLs: [groupRelay],
            additionalPrivateTags: [Event.Tag(name: "note", values: ["private-marker"])]
        )

        let event = try signer.signList(typed.list)
        #expect(event.kind == .simpleGroupList)
        #expect(try event.verify())
        // The private entries are encrypted: the content leaks neither ("-" and " " are
        // not base64 alphabet characters, so these strings cannot appear by chance).
        #expect(!event.content.isEmpty)
        #expect(!event.content.contains("secret-group-id"))
        #expect(!event.content.contains("Secret Kitchen"))
        #expect(!event.content.contains("private-marker"))

        let reread = try SimpleGroupList(list: signer.openList(event))
        #expect(reread == typed)

        // Without the author's key only the public face is visible.
        let publicView = try SimpleGroupList(list: NostrList(event: event))
        #expect(publicView.publicEntries == typed.publicEntries)
        #expect(publicView.relayURLs == typed.relayURLs)
        #expect(publicView.privateEntries.isEmpty)
        #expect(publicView.additionalPrivateTags.isEmpty)
    }
}

@Suite("NIP-51 Simple Group List Client Tests")
struct NIP51SimpleGroupListClientTests {

    private let firstRelayURL = URL(string: "wss://first.example.com")!
    private let secondRelayURL = URL(string: "wss://second.example.com")!
    private let groupID = "abcdef"
    private let groupRelay = "wss://groups.example.com"

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
        let counter = SocketCounter()
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

    /// Extracts the event of the first EVENT frame sent on `socket`.
    private func sentEvent(in socket: MockWebSocketSession) throws -> Event {
        guard let frame = socket.sentTextFrames.first(where: { $0.hasPrefix("[\"EVENT\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let eventDict = array[1] as? [String: Any]
        else {
            throw NostrError.invalidMessageFormat
        }
        let eventData = try JSONSerialization.data(withJSONObject: eventDict)
        return try JSONDecoder().decode(Event.self, from: eventData)
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
        try await NIP42TestSupport.pollUntil { self.hasEventFrame(socket) }
        let sent = try sentEvent(in: socket)
        socket.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        return sent
    }

    /// A canned `["EVENT", subscriptionId, {...}]` relay frame for `event`.
    private func eventFrame(subscriptionId: String, event: Event) throws -> String {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        return "[\"EVENT\",\"\(subscriptionId)\",\(json)]"
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

    /// Builds and signs a public-only kind-10009 list event at a pinned timestamp.
    private func listEvent(
        entries: [GroupListEntry],
        relayURLs: [String],
        createdAt: Int64,
        signer: EventSigner
    ) throws -> Event {
        let typed = SimpleGroupList(publicEntries: entries, relayURLs: relayURLs)
        return try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey,
                createdAt: createdAt,
                kind: .simpleGroupList,
                tags: typed.list.publicItems,
                content: ""
            )
        )
    }

    // MARK: - Publishing

    @Test("publishSimpleGroupList broadcasts the kind-10009 event to every relay in the pool")
    func publishBroadcastsToWholePool() async throws {
        let (client, firstSocket, secondSocket) = makeTwoSocketClient()
        let firstConnection = try await client.relayPool.addRelay(firstRelayURL)
        try await firstConnection.connect()
        let secondConnection = try await client.relayPool.addRelay(secondRelayURL)
        try await secondConnection.connect()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))

        let typed = SimpleGroupList(
            publicEntries: [GroupListEntry(groupID: groupID, relayURL: groupRelay, name: "Cooking")],
            relayURLs: [groupRelay]
        )
        let publishTask = Task { try await client.publishSimpleGroupList(typed, strategy: .allSettled) }
        let sentFirst = try await acknowledgePublish(on: firstSocket)
        let sentSecond = try await acknowledgePublish(on: secondSocket)
        let published = try await publishTask.value

        // Unlike the group flows' single-relay targeting, both relays receive the same event.
        #expect(sentFirst == sentSecond)
        #expect(sentFirst.kind == .simpleGroupList)
        #expect(
            sentFirst.structuredTags == [
                .simpleGroup(id: groupID, relayURL: groupRelay, name: "Cooking"),
                .reference(groupRelay),
            ]
        )
        #expect(sentFirst.content == "")
        #expect(try sentFirst.verify())
        #expect(published.event == sentFirst)
        #expect(Set(published.result.acceptedRelays) == [firstRelayURL, secondRelayURL])
        await client.disconnect()
    }

    // MARK: - Fetching

    @Test("fetchSimpleGroupList returns the newest typed list across stale copies")
    func fetchPicksNewest() async throws {
        let (client, socket) = makeClient()
        try await client.connect(to: [firstRelayURL.absoluteString])
        let author = EventSigner(keyPair: try KeyPair())
        let stale = try listEvent(
            entries: [GroupListEntry(groupID: "oldgrp", relayURL: "wss://old.example.com")],
            relayURLs: ["wss://old.example.com"],
            createdAt: 1_700_000_000,
            signer: author
        )
        let newer = try listEvent(
            entries: [GroupListEntry(groupID: "newgrp", relayURL: "wss://new.example.com", name: "Fresh")],
            relayURLs: ["wss://new.example.com"],
            createdAt: 1_700_000_100,
            signer: author
        )

        let fetched = try await answering(socket, with: [stale, newer]) {
            try await client.fetchSimpleGroupList(for: author.publicKey)
        }

        let list = try #require(fetched)
        #expect(
            list.publicEntries == [
                GroupListEntry(groupID: "newgrp", relayURL: "wss://new.example.com", name: "Fresh")
            ]
        )
        #expect(list.relayURLs == ["wss://new.example.com"])
        #expect(list.privateEntries.isEmpty)
        #expect(list.additionalPublicTags.isEmpty)

        let (_, filter) = try sentREQ(in: socket)
        #expect(filter["kinds"] as? [Int] == [10009])
        #expect(filter["authors"] as? [String] == [author.publicKey])
        await client.disconnect()
    }

    @Test("Fetching the current user's list decrypts private entries")
    func fetchOwnListDecryptsPrivateEntries() async throws {
        let (client, socket) = makeClient()
        try await client.connect(to: [firstRelayURL.absoluteString])
        let signer = EventSigner(keyPair: try KeyPair())
        await client.setSigner(signer)
        let typed = SimpleGroupList(
            publicEntries: [GroupListEntry(groupID: groupID, relayURL: groupRelay)],
            privateEntries: [GroupListEntry(groupID: "5ec4e7", relayURL: "wss://hidden.example.com")],
            relayURLs: [groupRelay]
        )
        let event = try signer.signList(typed.list)

        let fetched = try await answering(socket, with: [event]) {
            try await client.fetchSimpleGroupList()
        }

        #expect(fetched == typed)
        await client.disconnect()
    }
}

/// Hands out incrementing indexes to a factory closure that must stay `@Sendable`.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
