import Foundation
// Non-@testable import: the suite drives the transport entirely through NostrCore's public API,
// exactly as a NIP-46 signer session or a NIP-47 wallet connection does.
import NostrCore
import NostrTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Exercises ``RelayConnectionTransport`` over two in-memory relays: the fan-out of every
/// operation, the single stream their events merge into, and the degenerate no-relay case.
@Suite("Relay Connection Transport Tests")
struct RelayConnectionTransportTests {

    private static let relayURLs = [
        URL(string: "wss://relay-one.example.com")!,
        URL(string: "wss://relay-two.example.com")!,
    ]
    private static let subscriptionId = "sub-1"
    private static let eventId = String(repeating: "a", count: 64)
    private static let otherEventId = String(repeating: "d", count: 64)

    /// Thread-safe recorder for the events a ``RelayConnectionTransport/events()`` consumer sees.
    private final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Event] = []

        func append(_ event: Event) {
            lock.withLock { values.append(event) }
        }

        var ids: Set<String> {
            lock.withLock { Set(values.map(\.id)) }
        }
    }

    /// Thread-safe flag set by a consumer task when its stream ends.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            lock.withLock { value = true }
        }

        var isSet: Bool {
            lock.withLock { value }
        }
    }

    /// Hands out one mock socket per connection attempt, so each relay in the fan-out gets its
    /// own socket to drive and assert on. The transport connects its relays in order, so socket
    /// *n* belongs to relay *n*.
    private final class SocketDispenser: @unchecked Sendable {
        private let lock = NSLock()
        private var produced: [MockWebSocketSession] = []
        private let make: @Sendable (Int) -> MockWebSocketSession

        init(_ make: @escaping @Sendable (Int) -> MockWebSocketSession = { _ in MockWebSocketSession() }) {
            self.make = make
        }

        func next() -> MockWebSocketSession {
            lock.withLock {
                let session = make(produced.count)
                produced.append(session)
                return session
            }
        }

        func socket(at index: Int) -> MockWebSocketSession? {
            lock.withLock { produced.indices.contains(index) ? produced[index] : nil }
        }

        var count: Int {
            lock.withLock { produced.count }
        }
    }

    private func makeTransport(dispenser: SocketDispenser) -> RelayConnectionTransport {
        RelayConnectionTransport(
            relayURLs: Self.relayURLs,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { dispenser.next() }),
            // No auto-reconnect and a long ping interval keep the test's background
            // tasks inert; the transport is torn down explicitly at the end.
            config: RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
        )
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// Repeats `deliver` until `condition` holds, bounded like ``pollUntil(_:)``.
    ///
    /// ``RelayConnectionTransport/events()`` attaches to each relay's message stream on its own
    /// unstructured task, so a frame delivered immediately afterwards can reach the relay's
    /// receive loop before the attachment and be dropped — a relay connection does not replay.
    /// Re-delivering until the event is observed removes that race. A repeat is harmless: the
    /// transport already merges duplicate copies of one event arriving from several relays, and
    /// these tests assert on the set of event ids seen.
    private func deliverRepeatedly(
        _ deliver: @Sendable () throws -> Void,
        until condition: @Sendable () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try deliver()
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// The first frame the transport put on `mock` whose message type is `type` (`"REQ"`,
    /// `"CLOSE"`, `"EVENT"`), decoded from JSON so tests assert on the wire format rather than
    /// on substrings.
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

    /// A syntactically complete request event, as a session would publish it.
    private static func event(id: String) -> Event {
        Event(
            id: id,
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: .nostrConnect,
            tags: [],
            content: "sealed",
            sig: String(repeating: "c", count: 128))
    }

    /// An `EVENT` frame as a relay would send it, carrying a syntactically complete event.
    private static func eventFrame(eventId: String) throws -> String {
        let event: [String: Any] = [
            "id": eventId,
            "pubkey": String(repeating: "b", count: 64),
            "created_at": 1_700_000_000,
            "kind": Event.Kind.nostrConnect.rawValue,
            "tags": [],
            "content": "sealed",
            "sig": String(repeating: "c", count: 128),
        ]
        let frame: [Any] = ["EVENT", subscriptionId, event]
        return String(decoding: try JSONSerialization.data(withJSONObject: frame), as: UTF8.self)
    }

    // MARK: - Fan-out across relays

    @Test("connect starts a socket for every relay")
    func connectStartsEverySocket() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)

        try await transport.connect()

        #expect(dispenser.count == Self.relayURLs.count)
        #expect(dispenser.socket(at: 0)?.didResume == true)
        #expect(dispenser.socket(at: 1)?.didResume == true)
        await transport.disconnect()
    }

    @Test("subscribe REQs and unsubscribe CLOSEs every relay")
    func subscribeAndUnsubscribeReachEveryRelay() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)
        try await transport.connect()

        try await transport.subscribe(id: Self.subscriptionId, filters: [Filter(kinds: [.nostrConnect])])
        await transport.unsubscribe(id: Self.subscriptionId)

        for index in Self.relayURLs.indices {
            let mock = try #require(dispenser.socket(at: index))
            let request = try #require(Self.sentFrame("REQ", in: mock))
            #expect(request[1] as? String == Self.subscriptionId)
            let close = try #require(Self.sentFrame("CLOSE", in: mock))
            #expect(close[1] as? String == Self.subscriptionId)
        }
        await transport.disconnect()
    }

    @Test("send puts the event on every relay's socket")
    func sendReachesEveryRelay() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)
        try await transport.connect()

        try await transport.send(Self.event(id: Self.eventId))

        for index in Self.relayURLs.indices {
            let mock = try #require(dispenser.socket(at: index))
            let frame = try #require(Self.sentFrame("EVENT", in: mock))
            let event = try #require(frame[1] as? [String: Any])
            #expect(event["id"] as? String == Self.eventId)
        }
        await transport.disconnect()
    }

    @Test("events from both relays surface on the one merged stream")
    func eventsFromEveryRelayMerge() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)
        try await transport.connect()

        let received = EventLog()
        let stream = await transport.events()
        Task {
            for await event in stream {
                received.append(event)
            }
        }

        let relayOne = try #require(dispenser.socket(at: 0))
        let relayTwo = try #require(dispenser.socket(at: 1))
        try await deliverRepeatedly(
            {
                relayOne.deliver(.string(try Self.eventFrame(eventId: Self.eventId)))
                relayTwo.deliver(.string(try Self.eventFrame(eventId: Self.otherEventId)))
            },
            until: { received.ids == [Self.eventId, Self.otherEventId] }
        )

        await transport.disconnect()
    }

    @Test("connect succeeds when only one of two relays can connect")
    func connectToleratesOneUnreachableRelay() async throws {
        // The first relay's socket fails its verification ping, so only the second connects.
        let dispenser = SocketDispenser { index in
            MockWebSocketSession(pingError: index == 0 ? URLError(.cannotConnectToHost) : nil)
        }
        let transport = makeTransport(dispenser: dispenser)

        try await transport.connect()

        #expect(dispenser.count == Self.relayURLs.count)
        #expect(dispenser.socket(at: 1)?.didResume == true)
        await transport.disconnect()
    }

    // MARK: - Event stream lifecycle

    @Test("a second events() call finishes the first stream")
    func secondEventsCallFinishesTheFirstStream() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)
        try await transport.connect()

        let finished = Flag()
        let first = await transport.events()
        Task {
            for await _ in first {}
            finished.set()
        }

        _ = await transport.events()

        try await pollUntil { finished.isSet }
        await transport.disconnect()
    }

    @Test("disconnect finishes the events stream")
    func disconnectFinishesTheStream() async throws {
        let dispenser = SocketDispenser()
        let transport = makeTransport(dispenser: dispenser)
        try await transport.connect()

        let finished = Flag()
        let stream = await transport.events()
        Task {
            for await _ in stream {}
            finished.set()
        }

        await transport.disconnect()

        try await pollUntil { finished.isSet }
    }

    // MARK: - No relays

    @Test("connect throws notConnected when there are no relays")
    func connectWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: NostrError.notConnected) {
            try await transport.connect()
        }
    }

    @Test("subscribe throws notConnected when there are no relays")
    func subscribeWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: NostrError.notConnected) {
            try await transport.subscribe(id: Self.subscriptionId, filters: [Filter(kinds: [.nostrConnect])])
        }
    }

    @Test("send throws notConnected when there are no relays")
    func sendWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: NostrError.notConnected) {
            try await transport.send(Self.event(id: Self.eventId))
        }
    }

    @Test("events() finishes immediately when there are no relays")
    func eventsWithoutRelaysFinishes() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        let stream = await transport.events()

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("disconnect is safe when there are no relays")
    func disconnectWithoutRelays() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await transport.disconnect()
    }
}
