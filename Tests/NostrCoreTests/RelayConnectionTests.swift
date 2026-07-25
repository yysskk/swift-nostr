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

    private static let subscriptionId = "sub-1"
    private static let eventId = String(repeating: "a", count: 64)

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

    private func makeConnection() -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
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
    private static func eventFrame(subscriptionId: String, eventId: String) throws -> String {
        let event: [String: Any] = [
            "id": eventId,
            "pubkey": String(repeating: "b", count: 64),
            "created_at": 1_700_000_000,
            "kind": 1,
            "tags": [],
            "content": "hello",
            "sig": String(repeating: "c", count: 128),
        ]
        let frame: [Any] = ["EVENT", subscriptionId, event]
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
            subscriptionId: Self.subscriptionId,
            filters: [Filter(kinds: [.textNote], limit: 5)]
        )

        let frame = try #require(Self.sentFrame("REQ", in: mock))
        #expect(frame.count == 3)
        #expect(frame[1] as? String == Self.subscriptionId)
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

        mock.deliver(.string(try Self.eventFrame(subscriptionId: Self.subscriptionId, eventId: Self.eventId)))
        try await pollUntil { !received.snapshot.isEmpty }

        let message = try #require(received.snapshot.first)
        guard case .event(let subscriptionId, let event) = message else {
            Issue.record("expected an EVENT message, got \(message)")
            await connection.disconnect()
            return
        }
        #expect(subscriptionId == Self.subscriptionId)
        #expect(event.id == Self.eventId)
        #expect(event.content == "hello")
        await connection.disconnect()
    }

    @Test("unsubscribe sends a CLOSE frame for the subscription")
    func unsubscribeSendsCloseFrame() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()
        try await connection.subscribe(subscriptionId: Self.subscriptionId, filters: [Filter(kinds: [.textNote])])

        try await connection.unsubscribe(subscriptionId: Self.subscriptionId)

        let frame = try #require(Self.sentFrame("CLOSE", in: mock))
        #expect(frame.count == 2)
        #expect(frame[1] as? String == Self.subscriptionId)
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
