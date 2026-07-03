import Foundation
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

    private let relayURL = URL(string: "wss://relay.example.com")!

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
    }

    private func makeConnection(
        dispenser: SocketDispenser,
        maxReconnectAttempts: Int,
        initialReconnectDelay: TimeInterval = 0.001
    ) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { dispenser.next() }),
            config: RelayConnectionConfig(
                connectionTimeout: 1,
                pingInterval: 60,
                autoReconnect: true,
                maxReconnectAttempts: maxReconnectAttempts,
                initialReconnectDelay: initialReconnectDelay
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
        let connection = makeConnection(dispenser: dispenser, maxReconnectAttempts: 1)
        try await connection.connect()

        let finished = consume(await connection.messages())

        // Drop the connection; the single allowed reconnect attempt fails.
        dispenser.socket(at: 0)?.deliver(error: URLError(.networkConnectionLost))

        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    @Test("messages() finishes when disconnect() lands during a pending reconnect")
    func streamFinishesOnDisconnectDuringPendingReconnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        // A long backoff parks the reconnect task, leaving no receive loop alive.
        let connection = makeConnection(
            dispenser: dispenser, maxReconnectAttempts: 0, initialReconnectDelay: 60)
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
        let connection = makeConnection(dispenser: dispenser, maxReconnectAttempts: 0)

        let finished = consume(await connection.messages())

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    @Test("messages() finishes on disconnect() while connected")
    func streamFinishesOnDisconnectWhileConnected() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser, maxReconnectAttempts: 0)
        try await connection.connect()

        let finished = consume(await connection.messages())

        await connection.disconnect()
        try await NIP42TestSupport.pollUntil { finished.isSet }
    }

    // MARK: - Streams that must stay open

    @Test("messages() survives a successful auto-reconnect")
    func streamSurvivesSuccessfulReconnect() async throws {
        let dispenser = SocketDispenser { _ in MockWebSocketSession() }
        let connection = makeConnection(dispenser: dispenser, maxReconnectAttempts: 0)
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
        let connection = makeConnection(dispenser: dispenser, maxReconnectAttempts: 0)

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
