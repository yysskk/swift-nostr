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

    private let relayURL = RelayURL("wss://relay.example.com")!

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: .seconds(1), pingInterval: .seconds(60), reconnect: nil)
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
        throw RelayConnection.Error.timedOut
    }

    /// The COUNT frames the connection has sent so far.
    private func countFrames(in mock: MockWebSocketSession) -> [String] {
        mock.sentTextFrames.filter { $0.hasPrefix("[\"COUNT\"") }
    }

    /// Reads the generated subscription id from a sent COUNT frame.
    private func subscriptionID(fromCountFrame frame: String) throws -> String {
        guard let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let subscriptionID = array[1] as? String
        else {
            throw RelayMessage.Error.malformed
        }
        return subscriptionID
    }

    /// Waits for a COUNT frame, returning its generated subscription id.
    private func awaitCountSubscriptionID(in mock: MockWebSocketSession) async throws -> String {
        try await pollUntil { !countFrames(in: mock).isEmpty }
        return try subscriptionID(fromCountFrame: countFrames(in: mock)[0])
    }

    // MARK: - RelayConnection

    @Test("count resolves with the relay's reported count")
    func countHappyPath() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }

        let receivedID = try await awaitCountSubscriptionID(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(receivedID)\",{\"count\":238}]"))

        let result = try await task.value
        #expect(result == EventCount(value: 238, isApproximate: false))
        await connection.disconnect()
    }

    @Test("count surfaces the approximate flag")
    func countApproximate() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }

        let receivedID = try await awaitCountSubscriptionID(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(receivedID)\",{\"count\":93,\"approximate\":true}]"))

        let result = try await task.value
        #expect(result == EventCount(value: 93, isApproximate: true))
        await connection.disconnect()
    }

    @Test("count times out when the relay never replies")
    func countTimesOut() async throws {
        let (connection, _) = makeConnection()
        try await connection.connect()

        await #expect(throws: RelayConnection.Error.timedOut) {
            try await connection.countEvents(matching: [Filter(kinds: [.textNote])], timeout: .milliseconds(200))
        }
        await connection.disconnect()
    }

    @Test("count without a timeout times out after the connection's queryTimeout")
    func countWithoutTimeoutUsesQueryTimeout() async throws {
        let config = RelayConnectionConfig(
            connectionTimeout: .seconds(1), queryTimeout: .milliseconds(50), pingInterval: .seconds(60),
            reconnect: nil)
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            config: config
        )
        try await connection.connect()

        let start = ContinuousClock.now
        await #expect(throws: RelayConnection.Error.timedOut) {
            try await connection.countEvents(matching: [Filter(kinds: [.textNote])])
        }
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(40))
        #expect(elapsed < .seconds(5))
        await connection.disconnect()
    }

    @Test("count fails fast when the relay closes the subscription")
    func countClosed() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }

        let receivedID = try await awaitCountSubscriptionID(in: mock)
        mock.deliver(.string("[\"CLOSED\",\"\(receivedID)\",\"error: count not supported\"]"))

        await #expect(throws: RelayRejection(prefix: .error, message: "count not supported")) {
            try await task.value
        }
        await connection.disconnect()
    }

    @Test("disconnecting while a count is in flight fails it with notConnected")
    func countDisconnect() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }

        _ = try await awaitCountSubscriptionID(in: mock)
        await connection.disconnect()

        await #expect(throws: RelayConnection.Error.notConnected) {
            try await task.value
        }
    }

    @Test("concurrent counts get distinct subids and settle independently")
    func countConcurrent() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let taskA = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }
        let taskB = Task { try await connection.countEvents(matching: [Filter(kinds: [.setMetadata])]) }

        try await pollUntil { countFrames(in: mock).count == 2 }
        let frames = countFrames(in: mock)
        let firstID = try subscriptionID(fromCountFrame: frames[0])
        let secondID = try subscriptionID(fromCountFrame: frames[1])
        #expect(firstID != secondID)

        mock.deliver(.string("[\"COUNT\",\"\(firstID)\",{\"count\":10}]"))
        mock.deliver(.string("[\"COUNT\",\"\(secondID)\",{\"count\":20}]"))

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
        guard case .count(let subscriptionID, let count, _)? = message else {
            Issue.record("Expected a COUNT message on the messages() stream")
            await connection.disconnect()
            return
        }
        #expect(subscriptionID == "unrelated-sub")
        #expect(count == 5)
        await connection.disconnect()
    }

    @Test("count is one-shot: exactly one COUNT frame is sent and it is not tracked for replay")
    func countIsOneShot() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let task = Task { try await connection.countEvents(matching: [Filter(kinds: [.textNote])]) }
        let receivedID = try await awaitCountSubscriptionID(in: mock)
        mock.deliver(.string("[\"COUNT\",\"\(receivedID)\",{\"count\":1}]"))
        _ = try await task.value

        // The COUNT frame is a one-shot request: it is sent exactly once and never
        // registered as a subscription, so a reconnect would not replay it.
        #expect(countFrames(in: mock).count == 1)
        #expect(await connection.hasSubscription(SubscriptionID(rawValue: receivedID)) == false)
        await connection.disconnect()
    }

    // MARK: - RelayPool

    @Test("the pool count on an empty pool throws emptyPool")
    func poolCountOnEmptyPoolThrows() async {
        let pool = RelayPool()
        await #expect(throws: RelayPool.Error.emptyPool) {
            _ = try await pool.countEvents(matching: [Filter(kinds: [.textNote])])
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

        let urlA = RelayURL("wss://relay-a.example.com")!
        let urlB = RelayURL("wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(urlA)
        let connectionB = await pool.addRelay(urlB)
        // Connect sequentially so the factory pairs mockA with relay A.
        try await connectionA.connect()
        try await connectionB.connect()

        let task = Task { try await pool.countEvents(matching: [Filter(kinds: [.textNote])]) }

        try await pollUntil {
            mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
                && mockB.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
        }
        let subA = try subscriptionID(fromCountFrame: countFrames(in: mockA)[0])
        let subB = try subscriptionID(fromCountFrame: countFrames(in: mockB)[0])
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

        let urlA = RelayURL("wss://relay-a.example.com")!
        let urlB = RelayURL("wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(urlA)
        let connectionB = await pool.addRelay(urlB)
        try await connectionA.connect()
        try await connectionB.connect()

        // Relay A answers; relay B never replies and times out. The pool tolerates the
        // partial failure and returns only the relay that answered.
        let task = Task {
            try await pool.countEvents(matching: [Filter(kinds: [.textNote])], timeout: .seconds(2))
        }

        try await pollUntil { mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") } }
        let subA = try subscriptionID(fromCountFrame: countFrames(in: mockA)[0])
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

        let connectionA = await pool.addRelay(RelayURL("wss://relay-a.example.com")!)
        let connectionB = await pool.addRelay(RelayURL("wss://relay-b.example.com")!)
        try await connectionA.connect()
        try await connectionB.connect()

        // Neither relay replies; every per-relay count times out, so the pool surfaces the error.
        await #expect(throws: RelayConnection.Error.timedOut) {
            try await pool.countEvents(matching: [Filter(kinds: [.textNote])], timeout: .milliseconds(200))
        }
        await pool.disconnectAll()
    }

    @Test("the pool count without a timeout uses the pool's queryTimeout, not the relay's")
    func poolCountUsesPoolQueryTimeout() async throws {
        let mock = MockWebSocketSession()
        let relayConfig = RelayConnectionConfig(
            connectionTimeout: .seconds(1), queryTimeout: .seconds(30), pingInterval: .seconds(60),
            reconnect: nil)
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: relayConfig, queryTimeout: .milliseconds(50)),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let connection = await pool.addRelay(relayURL)
        try await connection.connect()

        // The relay never replies: the pool's 50 ms governs, not the connection's 30 s.
        let start = ContinuousClock.now
        await #expect(throws: RelayConnection.Error.timedOut) {
            try await pool.countEvents(matching: [Filter(kinds: [.textNote])])
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        await pool.disconnectAll()
    }

    @Test("an explicit pool count timeout overrides the pool's queryTimeout")
    func poolCountExplicitTimeoutOverridesQueryTimeout() async throws {
        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig, queryTimeout: .seconds(30)),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        let connection = await pool.addRelay(relayURL)
        try await connection.connect()

        let start = ContinuousClock.now
        await #expect(throws: RelayConnection.Error.timedOut) {
            try await pool.countEvents(matching: [Filter(kinds: [.textNote])], timeout: .milliseconds(50))
        }
        #expect(ContinuousClock.now - start < .seconds(5))
        await pool.disconnectAll()
    }

    // MARK: - NostrClient

    @Test("the client count targets only the requested relay via an alternate spelling")
    func clientCountTargetsOnlyRequestedRelay() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )
        let client = NostrClient(relayPool: pool)

        let urlA = RelayURL("wss://relay-a.example.com")!
        let connectionA = await pool.addRelay(urlA)
        let connectionB = await pool.addRelay(RelayURL("wss://relay-b.example.com")!)
        try await connectionA.connect()
        try await connectionB.connect()

        // Target relay A only, spelled differently from its pool key.
        let task = Task {
            try await client.events.countEvents(
                matching: [Filter(kinds: [.textNote])], route: .relays([RelayURL("WSS://Relay-A.example.com/")!]))
        }

        try await pollUntil { mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") } }
        let subA = try subscriptionID(fromCountFrame: countFrames(in: mockA)[0])
        mockA.deliver(.string("[\"COUNT\",\"\(subA)\",{\"count\":3}]"))

        let result = try await task.value
        #expect(result == 3)
        // The untargeted relay never saw a COUNT frame.
        #expect(!mockB.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") })
        await client.relays.disconnect()
    }

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

        let urlA = RelayURL("wss://relay-a.example.com")!
        let urlB = RelayURL("wss://relay-b.example.com")!
        let connectionA = await pool.addRelay(urlA)
        let connectionB = await pool.addRelay(urlB)
        try await connectionA.connect()
        try await connectionB.connect()

        let task = Task { try await client.events.countEvents(matching: [Filter(kinds: [.textNote])]) }

        try await pollUntil {
            mockA.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
                && mockB.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") }
        }
        let subA = try subscriptionID(fromCountFrame: countFrames(in: mockA)[0])
        let subB = try subscriptionID(fromCountFrame: countFrames(in: mockB)[0])
        mockA.deliver(.string("[\"COUNT\",\"\(subA)\",{\"count\":5}]"))
        mockB.deliver(.string("[\"COUNT\",\"\(subB)\",{\"count\":9}]"))

        let result = try await task.value
        #expect(result == 9)
        await client.relays.disconnect()
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
