import Foundation
// Non-@testable import: the suite drives a connection built on an injected transport
// entirely through NostrCore's public API, as a host on a platform-native socket would.
import NostrCore
import NostrTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Exercises a ``RelayConnection`` created through the WebSocket transport seam:
/// connecting, subscribing, receiving, unsubscribing, and tearing down against an
/// in-memory socket, with no network involved.
@Suite("Relay Connection Tests")
struct RelayConnectionTests {

    private static let subscriptionID = "sub-1"
    private static let eventID = String(repeating: "a", count: 64)

    /// Thread-safe recorder for the messages a ``RelayConnection/messages()`` consumer sees.
    private final class MessageLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RelayMessage] = []

        func append(_ message: RelayMessage) {
            lock.withLock { values.append(message) }
        }

        var snapshot: [RelayMessage] {
            lock.withLock { values }
        }
    }

    /// Counts the sockets a connection's factory hands out, i.e. its connection attempts.
    private final class SocketCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.withLock { count += 1 }
        }

        var value: Int {
            lock.withLock { count }
        }
    }

    private func makeConnection(socketCount: SocketCount = SocketCount()) -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: RelayURL("wss://relay.example.com")!,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: {
                socketCount.increment()
                return mock
            }),
            // No auto-reconnect and a long ping interval keep the test's background
            // tasks inert; the connection is torn down explicitly at the end.
            config: RelayConnectionConfig(
                connectionTimeout: .seconds(1), pingInterval: .seconds(60), autoReconnect: false)
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

    /// The first frame the connection sent whose message type is `type` (`"REQ"`, `"CLOSE"`, …),
    /// decoded from JSON so tests assert on the wire format rather than on substrings.
    private static func sentFrame(_ type: String, in mock: MockWebSocketSession) -> [Any]? {
        for text in mock.sentTextFrames {
            guard let data = text.data(using: .utf8),
                let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
                frame.first as? String == type
            else { continue }
            return frame
        }
        return nil
    }

    /// An `EVENT` frame as a relay would send it, carrying a syntactically complete event.
    private static func eventFrame(subscriptionID: String, eventID: String) throws -> String {
        let event: [String: Any] = [
            "id": eventID,
            "pubkey": String(repeating: "b", count: 64),
            "created_at": 1_700_000_000,
            "kind": 1,
            "tags": [],
            "content": "hello",
            "sig": String(repeating: "c", count: 128),
        ]
        let frame: [Any] = ["EVENT", subscriptionID, event]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    @Test("connecting through an injected factory starts the supplied socket")
    func connectUsesInjectedTransport() async throws {
        let (connection, mock) = makeConnection()

        try await connection.connect()

        #expect(await connection.state == .connected)
        #expect(mock.didResume)
        await connection.disconnect()
    }

    @Test("subscribe sends a REQ frame carrying the subscription id and filters")
    func subscribeSendsRequestFrame() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        try await connection.subscribe(
            subscriptionID: Self.subscriptionID,
            filters: [Filter(kinds: [.textNote], limit: 5)]
        )

        let frame = try #require(Self.sentFrame("REQ", in: mock))
        #expect(frame.count == 3)
        #expect(frame[1] as? String == Self.subscriptionID)
        let filter = try #require(frame[2] as? [String: Any])
        #expect(filter["kinds"] as? [Int] == [Event.Kind.textNote.rawValue])
        #expect(filter["limit"] as? Int == 5)
        await connection.disconnect()
    }

    @Test("an EVENT frame from the socket surfaces on messages()")
    func receivedEventReachesMessageStream() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let received = MessageLog()
        let stream = await connection.messages()
        Task {
            for await message in stream {
                received.append(message)
            }
        }

        mock.deliver(.string(try Self.eventFrame(subscriptionID: Self.subscriptionID, eventID: Self.eventID)))
        try await pollUntil { !received.snapshot.isEmpty }

        let message = try #require(received.snapshot.first)
        guard case .event(let subscriptionID, let event) = message else {
            Issue.record("expected an EVENT message, got \(message)")
            await connection.disconnect()
            return
        }
        #expect(subscriptionID == Self.subscriptionID)
        #expect(event.id.hex == Self.eventID)
        #expect(event.content == "hello")
        await connection.disconnect()
    }

    @Test("unsubscribe sends a CLOSE frame for the subscription")
    func unsubscribeSendsCloseFrame() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()
        try await connection.subscribe(subscriptionID: Self.subscriptionID, filters: [Filter(kinds: [.textNote])])

        await connection.unsubscribe(subscriptionID: Self.subscriptionID)

        let frame = try #require(Self.sentFrame("CLOSE", in: mock))
        #expect(frame.count == 2)
        #expect(frame[1] as? String == Self.subscriptionID)
        await connection.disconnect()
    }

    @Test("send on a disconnected connection throws notConnected without connecting")
    func sendWhileDisconnectedDoesNotConnect() async throws {
        let socketCount = SocketCount()
        let (connection, mock) = makeConnection(socketCount: socketCount)

        await #expect(throws: RelayConnection.Error.notConnected) {
            try await connection.send(.close(subscriptionID: Self.subscriptionID))
        }

        #expect(socketCount.value == 0)
        #expect(mock.sentTextFrames.isEmpty)
        #expect(await connection.state == .disconnected)
    }

    @Test("subscribe on a disconnected connection connects first")
    func subscribeWhileDisconnectedConnects() async throws {
        let socketCount = SocketCount()
        let (connection, mock) = makeConnection(socketCount: socketCount)

        try await connection.subscribe(subscriptionID: Self.subscriptionID, filters: [Filter(kinds: [.textNote])])

        #expect(socketCount.value == 1)
        #expect(await connection.state == .connected)
        #expect(Self.sentFrame("REQ", in: mock) != nil)
        await connection.disconnect()
    }

    @Test("unsubscribe on a never-connected connection does not connect")
    func unsubscribeWhileDisconnectedDoesNotConnect() async throws {
        let socketCount = SocketCount()
        let (connection, mock) = makeConnection(socketCount: socketCount)

        await connection.unsubscribe(subscriptionID: Self.subscriptionID)

        #expect(socketCount.value == 0)
        #expect(mock.sentTextFrames.isEmpty)
        #expect(await connection.state == .disconnected)
    }

    @Test("unsubscribe after a drop forgets the subscription without reconnecting")
    func unsubscribeAfterDropForgetsSubscriptionWithoutReconnecting() async throws {
        let socketCount = SocketCount()
        let (connection, mock) = makeConnection(socketCount: socketCount)
        try await connection.subscribe(subscriptionID: Self.subscriptionID, filters: [Filter(kinds: [.textNote])])

        mock.deliver(error: URLError(.networkConnectionLost))
        try await pollUntil {
            if case .failed = await connection.state { return true }
            return false
        }
        #expect(await connection.hasSubscription(Self.subscriptionID))

        await connection.unsubscribe(subscriptionID: Self.subscriptionID)

        #expect(socketCount.value == 1)
        #expect(Self.sentFrame("CLOSE", in: mock) == nil)
        #expect(await !connection.hasSubscription(Self.subscriptionID))
        await connection.disconnect()
    }

    @Test("unsubscribe sends no CLOSE for a subscription the connection does not hold")
    func unsubscribeUnknownSubscriptionSendsNothing() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        await connection.unsubscribe(subscriptionID: Self.subscriptionID)

        #expect(Self.sentFrame("CLOSE", in: mock) == nil)
        await connection.disconnect()
    }

    @Test("disconnect returns the connection to the disconnected state")
    func disconnectResetsState() async throws {
        let (connection, _) = makeConnection()
        try await connection.connect()
        #expect(await connection.state == .connected)

        await connection.disconnect()

        #expect(await connection.state == .disconnected)
    }
}

@Suite("Relay Connection URL Tests")
struct RelayConnectionURLTests {

    @Test("a connection keeps its relay URL in canonical form")
    func keepsCanonicalURL() throws {
        let connection = RelayConnection(url: try RelayURL(string: "WSS://Relay.Example.com:443/"))
        #expect(connection.url == RelayURL("wss://relay.example.com")!)
        #expect(connection.url.url.absoluteString == "wss://relay.example.com")
    }
}
