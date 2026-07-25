import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-45 Count Tests")
struct NIP45CountTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    private func makeConnection() -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            config: noReconnectConfig
        )
        return (connection, mock)
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// The COUNT frames the connection has sent so far.
    private func countFrames(in mock: MockWebSocketSession) -> [String] {
        mock.sentTextFrames.filter { $0.hasPrefix("[\"COUNT\"") }
    }

    /// Reads the generated subscription id from a sent COUNT frame.
    private func subscriptionId(fromCountFrame frame: String) throws -> String {
        guard let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let subscriptionId = array[1] as? String
        else {
            throw NostrError.invalidMessageFormat
        }
        return subscriptionId
    }

    /// Waits for a COUNT frame, returning its generated subscription id.
    private func awaitCountSubscriptionId(in mock: MockWebSocketSession) async throws -> String {
        try await pollUntil { !countFrames(in: mock).isEmpty }
        return try subscriptionId(fromCountFrame: countFrames(in: mock)[0])
    }

    // MARK: - RelayConnection

    @Test("count resolves with the relay's reported count")
    func countHappyPath() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }

        let subId = try await awaitCountSubscriptionId(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(subId)\",{\"count\":238}]"))

        let result = try await task.value
        #expect(result == EventCount(value: 238, isApproximate: false))
        await connection.disconnect()
    }

    @Test("count surfaces the approximate flag")
    func countApproximate() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }

        let subId = try await awaitCountSubscriptionId(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(subId)\",{\"count\":93,\"approximate\":true}]"))

        let result = try await task.value
        #expect(result == EventCount(value: 93, isApproximate: true))
        await connection.disconnect()
    }

    @Test("count times out when the relay never replies")
    func countTimesOut() async throws {
        let (connection, _) = makeConnection()
        try await connection.connect()

        await #expect(throws: NostrError.timeout) {
            try await connection.count(filters: [Filter(kinds: [.textNote])], timeout: 0.2)
        }
        await connection.disconnect()
    }

    @Test("count fails fast when the relay closes the subscription")
    func countClosed() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }

        let subId = try await awaitCountSubscriptionId(in: mock)
        mock.deliver(.string("[\"CLOSED\",\"\(subId)\",\"error: count not supported\"]"))

        await #expect(throws: NostrError.relayError("error: count not supported")) {
            try await task.value
        }
        await connection.disconnect()
    }

    @Test("disconnecting while a count is in flight fails it with notConnected")
    func countDisconnect() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }

        _ = try await awaitCountSubscriptionId(in: mock)
        await connection.disconnect()

        await #expect(throws: NostrError.notConnected) {
            try await task.value
        }
    }

    @Test("concurrent counts get distinct subids and settle independently")
    func countConcurrent() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let taskA = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }
        let taskB = Task { try await connection.count(filters: [Filter(kinds: [.setMetadata])]) }

        try await pollUntil { countFrames(in: mock).count == 2 }
        let frames = countFrames(in: mock)
        let subId0 = try subscriptionId(fromCountFrame: frames[0])
        let subId1 = try subscriptionId(fromCountFrame: frames[1])
        #expect(subId0 != subId1)

        mock.deliver(.string("[\"COUNT\",\"\(subId0)\",{\"count\":10}]"))
        mock.deliver(.string("[\"COUNT\",\"\(subId1)\",{\"count\":20}]"))

        let counts = Set([try await taskA.value.value, try await taskB.value.value])
        #expect(counts == [10, 20])
        await connection.disconnect()
    }

    @Test("a messages() consumer also observes the COUNT message")
    func countObservedOnMessagesStream() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let observed = Task { () -> RelayMessage? in
            for await message in await connection.messages() {
                if case .count = message { return message }
            }
            return nil
        }

        // Yield so the message stream is iterating before the frame is delivered.
        await Task.yield()
        mock.deliver(.string("[\"COUNT\",\"unrelated-sub\",{\"count\":5}]"))

        let message = await observed.value
        guard case .count(let subscriptionId, let count, _)? = message else {
            Issue.record("Expected a COUNT message on the messages() stream")
            await connection.disconnect()
            return
        }
        #expect(subscriptionId == "unrelated-sub")
        #expect(count == 5)
        await connection.disconnect()
    }

    @Test("count is one-shot: exactly one COUNT frame is sent and it is not tracked for replay")
    func countIsOneShot() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.count(filters: [Filter(kinds: [.textNote])]) }
        let subId = try await awaitCountSubscriptionId(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(subId)\",{\"count\":1}]"))
        _ = try await task.value

        // The COUNT frame is a one-shot request: it is sent exactly once and never
        // registered as a subscription, so a reconnect would not replay it.
        #expect(countFrames(in: mock).count == 1)
        #expect(await connection.hasSubscription(subId) == false)
        await connection.disconnect()
    }

    // MARK: - RelayPool

    @Test("the pool count on an empty pool throws noRelaysInPool")
    func poolCountOnEmptyPoolThrows() async {
        let pool = RelayPool()
        await #expect(throws: NostrError.noRelaysInPool) {
            _ = try await pool.count(filters: [Filter(kinds: [.textNote])])
        }
    }

    @Test("the pool returns a per-relay count from every relay that answers")
    func poolCount() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )

        let urlA = URL(string: "wss://relay-a.example.com")!
        let urlB = URL(string: "wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(url: urlA)
        let connectionB = await pool.addRelay(url: urlB)
        // Connect sequentially so the factory pairs mockA with relay A.
        try await connectionA.connect()
        try await connectionB.connect()

        let task = Task { try await pool.count(filters: [Filter(kinds: [.textNote])]) }

        try await pollUntil {
            mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
                && mockB.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
        }
        let subA = try subscriptionId(fromCountFrame: countFrames(in: mockA)[0])
        let subB = try subscriptionId(fromCountFrame: countFrames(in: mockB)[0])
        mockA.deliver(.string("[\"COUNT\",\"\(subA)\",{\"count\":5}]"))
        mockB.deliver(.string("[\"COUNT\",\"\(subB)\",{\"count\":9}]"))

        let results = try await task.value
        #expect(results[urlA] == EventCount(value: 5))
        #expect(results[urlB] == EventCount(value: 9))
        await pool.disconnectAll()
    }

    @Test("the pool tolerates a relay that never answers and returns only the replies")
    func poolCountToleratesPartialFailure() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )

        let urlA = URL(string: "wss://relay-a.example.com")!
        let urlB = URL(string: "wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(url: urlA)
        let connectionB = await pool.addRelay(url: urlB)
        try await connectionA.connect()
        try await connectionB.connect()

        // Relay A answers; relay B never replies and times out. The pool tolerates the
        // partial failure and returns only the relay that answered.
        let task = Task { try await pool.count(filters: [Filter(kinds: [.textNote])], timeout: 0.3) }

        try await pollUntil { mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") } }
        let subA = try subscriptionId(fromCountFrame: countFrames(in: mockA)[0])
        mockA.deliver(.string("[\"COUNT\",\"\(subA)\",{\"count\":7}]"))

        let results = try await task.value
        #expect(results[urlA] == EventCount(value: 7))
        #expect(results[urlB] == nil)
        #expect(results.count == 1)
        await pool.disconnectAll()
    }

    @Test("the pool count throws when no targeted relay answers")
    func poolCountThrowsWhenNoneAnswer() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )

        let connectionA = await pool.addRelay(url: URL(string: "wss://relay-a.example.com")!)
        let connectionB = await pool.addRelay(url: URL(string: "wss://relay-b.example.com")!)
        try await connectionA.connect()
        try await connectionB.connect()

        // Neither relay replies; every per-relay count times out, so the pool surfaces the error.
        await #expect(throws: NostrError.timeout) {
            try await pool.count(filters: [Filter(kinds: [.textNote])], timeout: 0.2)
        }
        await pool.disconnectAll()
    }

    // MARK: - NostrClient

    @Test("the client returns the maximum count across relays")
    func clientCountReturnsMax() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )
        let client = NostrClient(relayPool: pool)

        let urlA = URL(string: "wss://relay-a.example.com")!
        let urlB = URL(string: "wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(url: urlA)
        let connectionB = await pool.addRelay(url: urlB)
        try await connectionA.connect()
        try await connectionB.connect()

        let task = Task { try await client.count(filters: [Filter(kinds: [.textNote])]) }

        try await pollUntil {
            mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
                && mockB.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
        }
        let subA = try subscriptionId(fromCountFrame: countFrames(in: mockA)[0])
        let subB = try subscriptionId(fromCountFrame: countFrames(in: mockB)[0])
        mockA.deliver(.string("[\"COUNT\",\"\(subA)\",{\"count\":5}]"))
        mockB.deliver(.string("[\"COUNT\",\"\(subB)\",{\"count\":9}]"))

        let result = try await task.value
        #expect(result == 9)
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
