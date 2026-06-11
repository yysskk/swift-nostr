import Foundation
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("Relay Connection Transport Tests")
struct RelayConnectionTransportTests {

    private func makeConnection(pingError: Error? = nil) -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession(pingError: pingError)
        let connection = RelayConnection(
            url: URL(string: "wss://relay.example.com")!,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            // No auto-reconnect and a long ping interval keep the test's background
            // tasks inert; the connection is torn down explicitly at the end.
            config: RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
        )
        return (connection, mock)
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    private static func eventFrame(subscriptionId: String, eventId: String) -> String {
        let eventDict: [String: Any] = [
            "id": eventId,
            "pubkey": String(repeating: "b", count: 64),
            "created_at": 1_700_000_000,
            "kind": 1,
            "tags": [],
            "content": "hello",
            "sig": String(repeating: "c", count: 128),
        ]
        let array: [Any] = ["EVENT", subscriptionId, eventDict]
        let data = try! JSONSerialization.data(withJSONObject: array)
        return String(data: data, encoding: .utf8)!
    }

    @Test("connect succeeds against a fake socket whose ping resolves")
    func connectSucceeds() async throws {
        let (connection, mock) = makeConnection()

        try await connection.connect()

        #expect(await connection.state == .connected)
        #expect(mock.didResume)
        await connection.disconnect()
    }

    @Test("connect fails when the ping reports an error")
    func connectFailsOnPingError() async {
        let (connection, _) = makeConnection(pingError: URLError(.cannotConnectToHost))

        await #expect(throws: NostrError.self) {
            try await connection.connect()
        }
        #expect(await connection.state != .connected)
    }

    @Test("subscribe forwards a REQ frame to the socket")
    func subscribeForwardsRequest() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        try await connection.subscribe(subscriptionId: "sub-1", filters: [Filter(kinds: [1])])

        #expect(mock.sentTextFrames.contains { $0.contains("\"REQ\"") && $0.contains("sub-1") })
        await connection.disconnect()
    }

    @Test("received EVENT frames are parsed and delivered to messages()")
    func receiveDeliversParsedMessages() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let stream = await connection.messages()
        mock.deliver(.string(Self.eventFrame(subscriptionId: "sub-1", eventId: String(repeating: "a", count: 64))))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()

        guard case .event(let subscriptionId, _) = received else {
            Issue.record("expected an event message, got \(String(describing: received))")
            await connection.disconnect()
            return
        }
        #expect(subscriptionId == "sub-1")
        await connection.disconnect()
    }

    @Test("publish resolves when the relay returns OK for the event")
    func publishResolvesOnOK() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let event = Event(
            id: String(repeating: "d", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "gm",
            sig: String(repeating: "c", count: 128)
        )

        let publishTask = Task { try await connection.publish(event) }

        // Deliver the OK only once the EVENT frame has been sent, so the publish
        // waiter is registered when the acknowledgment arrives.
        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"EVENT\"") } }
        mock.deliver(.string("[\"OK\",\"\(event.id)\",true,\"\"]"))

        try await publishTask.value
        await connection.disconnect()
    }
}
