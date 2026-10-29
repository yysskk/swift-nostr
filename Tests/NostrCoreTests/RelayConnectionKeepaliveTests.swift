import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// The keepalive pings a connected socket every `pingInterval` and bounds each pong by
/// `connectionTimeout`. Each test answers the pings by hand through a deferred mock, so the
/// outcome of every ping is chosen by the test rather than by timing.
@Suite("RelayConnection Keepalive Tests")
struct RelayConnectionKeepaliveTests {
    private struct PingFailure: Swift.Error {}

    private func makeConnection(
        pongTimeout: Duration,
        reconnect: ReconnectPolicy? = nil,
        makeSession: @escaping @Sendable () -> MockWebSocketSession
    ) -> RelayConnection {
        let config = RelayConnectionConfig(
            connectionTimeout: pongTimeout, pingInterval: .milliseconds(10), reconnect: reconnect)
        return RelayConnection(
            url: RelayURL("wss://relay.example.com")!,
            config: config,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: makeSession)
        )
    }

    /// Connects through `socket`, whose handshake ping is answered at once (`immediatePings: 1`),
    /// so a short pong timeout bounds only the keepalive pings the test answers by hand.
    private func connect(_ connection: RelayConnection, through socket: MockWebSocketSession) async throws {
        try await connection.connect()
    }

    /// Suspends until `connection` reports a state matching `predicate`.
    private func waitForState(
        of connection: RelayConnection,
        where predicate: @Sendable (RelayConnectionState) -> Bool
    ) async {
        for await state in await connection.stateChanges() where predicate(state) {
            return
        }
    }

    private static func isFailed(_ state: RelayConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    @Test("an answered keepalive ping keeps the connection up", .timeLimit(.minutes(1)))
    func answeredPingStaysConnected() async throws {
        let socket = MockWebSocketSession(defersPing: true, immediatePings: 1)
        let connection = makeConnection(pongTimeout: .seconds(30)) { socket }
        try await connect(connection, through: socket)

        await socket.waitForPing()
        socket.completePing()
        // A second ping only starts once the first one succeeded and the loop went round again.
        await socket.waitForPing()

        #expect(await connection.state == .connected)
        #expect(!socket.didClose)
        socket.completePing()
        await connection.disconnect()
    }

    @Test("a failed keepalive ping drops the connection", .timeLimit(.minutes(1)))
    func failedPingDropsConnection() async throws {
        let socket = MockWebSocketSession(defersPing: true, immediatePings: 1)
        let connection = makeConnection(pongTimeout: .seconds(30)) { socket }
        try await connect(connection, through: socket)

        await socket.waitForPing()
        socket.completePing(error: PingFailure())

        await waitForState(of: connection, where: Self.isFailed)
        #expect(socket.didClose)
    }

    /// The mock's deferred ping ignores cancellation and the socket closing, so it stays suspended
    /// the whole time: only the connection's own timeout can end the wait.
    @Test("a keepalive ping that never returns still times out", .timeLimit(.minutes(1)))
    func unansweredPingTimesOut() async throws {
        let socket = MockWebSocketSession(defersPing: true, immediatePings: 1)
        let connection = makeConnection(pongTimeout: .milliseconds(100)) { socket }
        try await connect(connection, through: socket)

        await socket.waitForPing()
        await waitForState(of: connection, where: Self.isFailed)

        #expect(socket.didClose)
        #expect(socket.pendingPingCount == 1)
        socket.completePing()
    }

    @Test("a keepalive timeout reconnects on a fresh socket", .timeLimit(.minutes(1)))
    func unansweredPingReconnects() async throws {
        let first = MockWebSocketSession(defersPing: true, immediatePings: 1)
        let replacements = SocketCounter()
        let reconnect = ReconnectPolicy(initialDelay: .milliseconds(10))
        let connection = makeConnection(pongTimeout: .milliseconds(100), reconnect: reconnect) {
            replacements.next(after: first)
        }
        try await connect(connection, through: first)

        await first.waitForPing()
        await waitForState(of: connection, where: Self.isFailed)
        await waitForState(of: connection) { $0 == .connected }

        #expect(replacements.count >= 1)
        #expect(first.didClose)
        first.completePing()
        await connection.disconnect()
    }
}

/// Hands out `first` for the initial connection and a fresh, immediately answering socket after.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var handedOutFirst = false
    private var replacementCount = 0

    func next(after first: MockWebSocketSession) -> MockWebSocketSession {
        let isFirst: Bool = lock.withLock {
            defer { handedOutFirst = true }
            if handedOutFirst { replacementCount += 1 }
            return !handedOutFirst
        }
        return isFirst ? first : MockWebSocketSession()
    }

    /// How many replacement sockets were handed out.
    var count: Int {
        lock.withLock { replacementCount }
    }
}
