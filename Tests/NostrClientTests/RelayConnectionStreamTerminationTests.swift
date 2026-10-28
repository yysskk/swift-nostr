import Foundation
import NostrTestSupport
import Testing

@testable import NostrClient
@testable import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Verifies when ``RelayConnection/messages()`` streams finish: on every terminal
/// teardown (explicit disconnect, auto-reconnect giving up) and never across a
/// successful automatic reconnection.
@Suite("Relay Connection Stream Termination Tests")
struct RelayConnectionStreamTerminationTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    /// Thread-safe flag set by consumer tasks when their stream ends.
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

    /// Thread-safe recorder for observed connection states.
    private final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [RelayConnectionState] = []

        func append(_ state: RelayConnectionState) {
            lock.withLock { values.append(state) }
        }

        var snapshot: [RelayConnectionState] {
            lock.withLock { values }
        }
    }

    /// Hands out one mock socket per connection attempt so reconnection tests can
    /// shape each session — e.g. a healthy first socket and failing later ones.
    private final class SocketDispenser: @unchecked Sendable {
        private let lock = NSLock()
        private var produced: [MockWebSocketSession] = []
        private let make: @Sendable (Int) -> MockWebSocketSession

        init(_ make: @escaping @Sendable (Int) -> MockWebSocketSession) {
            self.make = make
        }

        func next() -> MockWebSocketSession {
            lock.lock()
            defer { lock.unlock() }
            let session = make(produced.count)
            produced.append(session)
            return session
        }

        func socket(at index: Int) -> MockWebSocketSession? {
            lock.lock()
            defer { lock.unlock() }
            return produced.indices.contains(index) ? produced[index] : nil
        }

        /// The number of sockets handed out, one per connection attempt.
        var count: Int {
            lock.withLock { produced.count }
        }
    }

    private func makeConnection(
        dispenser: SocketDispenser,
        reconnect: ReconnectPolicy? = ReconnectPolicy(initialDelay: .milliseconds(1))
    ) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { dispenser.next() }),
            config: RelayConnectionConfig(
                connectionTimeout: .seconds(1),
                pingInterval: .seconds(60),
                reconnect: reconnect
            )
        )
    }

    /// Starts consuming `stream` and returns a flag that is set when it finishes.
    private func consume(_ stream: AsyncStream<RelayMessage>) -> Flag {
        let finished = Flag()
        Task {
            for await _ in stream {}
            finished.set()
        }
        return finished
    }

    // MARK: - Terminal teardown paths

    @Test("messages() finishes when auto-reconnect gives up")
    func streamFinishesWhenReconnectGivesUp() async throws {
        // Socket 0 connects fine; every reconnect attempt fails its verification ping.
        let dispenser = SocketDispenser { index in
            MockWebSocketSession(pingError: index == 0 ? nil : URLError(.cannotConnectToHost))
        }
        let policy = ReconnectPolicy(maximumAttempts: 1, initialDelay: .milliseconds(1))
        let connection = makeConnection(dispenser: dispenser, reconnect: policy)
        try await connection.connect()

        let finished = consume(await connection.messages())

        // Drop the connection; the single allowed reconnect attempt fails.
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    @Test("messages() finishes when the connection drops with auto-reconnect disabled")
    func streamFinishesOnDropWithoutAutoReconnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser, reconnect: nil)
        try await connection.connect()

        let finished = consume(await connection.messages())

        // With auto-reconnect off, a dropped socket is terminal: the receive
        // loop exits with isReconnecting false and finishes the streams.
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        try await NIP42TestSupport.pollUntil { finished.isSet }
        #expect(dispenser.count == 1)
    }

    @Test("a dropped connection makes exactly maximumAttempts reconnection attempts")
    func reconnectStopsAfterMaximumAttempts() async throws {
        let dispenser = SocketDispenser { index in
            MockWebSocketSession(pingError: index == 0 ? nil : URLError(.cannotConnectToHost))
        }
        // A fixed rate keeps every wait at the 100 ms floor, so three attempts fit the poll budget.
        let policy = ReconnectPolicy(maximumAttempts: 3, initialDelay: .zero, backoffMultiplier: 1)
        let connection = makeConnection(dispenser: dispenser, reconnect: policy)
        try await connection.connect()

        let finished = consume(await connection.messages())
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        try await NIP42TestSupport.pollUntil { finished.isSet }
        // The original socket plus one per attempt, and none after giving up.
        #expect(dispenser.count == 4)
        #expect(await connection.state != .connected)
    }

    @Test("a maximum of zero attempts makes the first drop final", arguments: [0, -1])
    func zeroMaximumAttemptsNeverReconnects(maximumAttempts: Int) async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let policy = ReconnectPolicy(maximumAttempts: maximumAttempts, initialDelay: .zero)
        let connection = makeConnection(dispenser: dispenser, reconnect: policy)
        try await connection.connect()

        let finished = consume(await connection.messages())
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        try await NIP42TestSupport.pollUntil { finished.isSet }
        #expect(dispenser.count == 1)
    }

    @Test("with no attempt limit, failed reconnections keep being retried")
    func unlimitedAttemptsKeepRetrying() async throws {
        let dispenser = SocketDispenser { index in
            MockWebSocketSession(pingError: index == 0 ? nil : URLError(.cannotConnectToHost))
        }
        let policy = ReconnectPolicy(maximumAttempts: nil, initialDelay: .zero, backoffMultiplier: 1)
        let connection = makeConnection(dispenser: dispenser, reconnect: policy)
        try await connection.connect()

        let finished = consume(await connection.messages())
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        // Past any small limit, attempts continue and the stream stays open.
        try await NIP42TestSupport.pollUntil { dispenser.count >= 5 }
        #expect(!finished.isSet)

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    @Test("messages() finishes when disconnect() lands during a pending reconnect")
    func streamFinishesOnDisconnectDuringPendingReconnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        // A long backoff parks the reconnect task, leaving no receive loop alive.
        let connection = makeConnection(dispenser: dispenser, reconnect: ReconnectPolicy(initialDelay: .seconds(60)))
        try await connection.connect()

        let finished = consume(await connection.messages())

        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))
        // The receive loop exits keeping the stream open for the parked reconnect.
        try await NIP42TestSupport.pollUntil { await connection.state != .connected }
        #expect(!finished.isSet)

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
        #expect(await connection.state == .disconnected)
    }

    @Test("messages() finishes on disconnect() when never connected")
    func streamFinishesOnDisconnectWhenNeverConnected() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser)

        let finished = consume(await connection.messages())

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    @Test("messages() finishes on disconnect() while connected")
    func streamFinishesOnDisconnectWhileConnected() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser)
        try await connection.connect()

        let finished = consume(await connection.messages())

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    // MARK: - Streams that must stay open

    @Test("messages() survives a successful auto-reconnect")
    func streamSurvivesSuccessfulReconnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser)
        try await connection.connect()

        let received = Flag()
        let stream = await connection.messages()
        Task {
            for await message in stream {
                if case .notice = message {
                    received.set()
                }
            }
        }

        // Drop the first session; the automatic reconnect brings up socket 1.
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))
        try await NIP42TestSupport.pollUntil {
            guard dispenser.socket(at: 1) != nil else { return false }
            return await connection.state == .connected
        }

        // A message from the new session reaches the pre-reconnect stream.
        dispenser.socket(at: 1)?.deliver(.string(#"["NOTICE","welcome back"]"#))
        try await NIP42TestSupport.pollUntil { received.isSet }

        await connection.disconnect()
    }

    @Test("stateChanges() stays open across disconnect and reconnect")
    func stateStreamStaysOpenAcrossDisconnectAndConnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser)

        let states = StateLog()
        let stream = await connection.stateChanges()
        Task {
            for await state in stream {
                states.append(state)
            }
        }

        try await connection.connect()
        await connection.disconnect()
        try await connection.connect()

        // The same stream observes the disconnect and the connection after it.
        try await NIP42TestSupport.pollUntil {
            let snapshot = states.snapshot
            guard let disconnectedIndex = snapshot.firstIndex(of: .disconnected) else { return false }
            return snapshot[disconnectedIndex...].contains(.connected)
        }

        await connection.disconnect()
    }
}
