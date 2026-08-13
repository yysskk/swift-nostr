import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// A connection attempt suspends while it waits for the pong that proves the socket works, and the
/// connection can be torn down or replaced during that wait. Whatever resumes afterwards has to
/// know whether the socket it was working on is still the live one — otherwise it reports on a
/// session that no longer exists.
@Suite("Relay Connection Socket Generation Tests")
struct RelayConnectionSocketGenerationTests {
    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeConnection(
        sockets: @escaping @Sendable () -> MockWebSocketSession
    ) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: sockets),
            config: RelayConnectionConfig(autoReconnect: false)
        )
    }

    /// The wedge: `disconnect()` lands while an attempt waits on its pong, the pong then arrives,
    /// and the attempt marks the connection `.connected` for a socket that was already discarded.
    /// The state says healthy, so `connect()` returns early without doing anything, while `send`
    /// finds no socket and throws — permanently, with no reconnect pending.
    @Test("a connect attempt superseded by disconnect does not report connected")
    func supersededAttemptDoesNotReportConnected() async throws {
        let socket = MockWebSocketSession(defersPing: true)
        let connection = makeConnection(sockets: { socket })

        let attempt = Task { try await connection.connect() }
        await socket.waitForPing()

        await connection.disconnect()
        socket.completePing()

        // The attempt must report failure rather than success over a discarded socket.
        await #expect(throws: (any Error).self) { try await attempt.value }

        let state = await connection.state
        #expect(state == .disconnected)
    }

    /// The consequence that makes the wedge permanent: with the state left at `.connected`,
    /// `connect()` short-circuits and the connection can never be revived.
    @Test("a connection superseded during connect can be reconnected afterwards")
    func supersededConnectionCanReconnect() async throws {
        let sockets = SocketSequence(defersPingForFirst: true)
        let connection = makeConnection(sockets: { sockets.next() })

        let attempt = Task { try await connection.connect() }
        await sockets.first.waitForPing()
        await connection.disconnect()
        sockets.first.completePing()
        _ = try? await attempt.value

        // A fresh connect must actually establish a session, not return early on a stale state.
        try await connection.connect()

        let state = await connection.state
        #expect(state == .connected)
        #expect(sockets.second.didResume)

        await connection.disconnect()
    }

    /// A socket being replaced has to be closed, not merely dropped: an abandoned socket is a live
    /// connection nobody will close, and its receive loop goes on running beside the new one.
    @Test("a replaced socket is cancelled rather than abandoned")
    func replacedSocketIsCancelled() async throws {
        let sockets = SocketSequence(defersPingForFirst: false)
        let connection = makeConnection(sockets: { sockets.next() })

        try await connection.connect()
        #expect(!sockets.first.didCancel)

        // Dropping the transport fails the receive loop, which tears the session down.
        await connection.disconnect()
        #expect(sockets.first.didCancel)
    }

    /// After teardown nothing should still be running against the old socket, so a frame arriving
    /// on it cannot reach a consumer of the next session.
    @Test("teardown stops the receive loop")
    func teardownStopsReceiveLoop() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(sockets: { socket })

        try await connection.connect()
        let messages = await connection.messages()
        await connection.disconnect()

        // The stream ends because disconnect finished it; nothing further is delivered.
        var received: [RelayMessage] = []
        socket.deliver(.string(#"["NOTICE","after teardown"]"#))
        for await message in messages {
            received.append(message)
        }

        #expect(received.isEmpty)
    }
}

/// Hands out a fixed pair of sockets in order, so a test can address the first and second
/// connection attempts separately.
private final class SocketSequence: @unchecked Sendable {
    let first: MockWebSocketSession
    let second: MockWebSocketSession
    private let lock = NSLock()
    private var handedOut = 0

    init(defersPingForFirst: Bool) {
        first = MockWebSocketSession(defersPing: defersPingForFirst)
        second = MockWebSocketSession()
    }

    func next() -> MockWebSocketSession {
        lock.lock()
        defer { lock.unlock() }
        handedOut += 1
        return handedOut == 1 ? first : second
    }
}
