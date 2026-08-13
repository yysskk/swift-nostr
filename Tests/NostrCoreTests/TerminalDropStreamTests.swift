import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// A drop that no reconnect will follow is terminal, and the `messages()` contract says the streams
/// end there. The receive loop cannot be the one to do it: a drop routed through `discardSocket()`
/// retires the loop's generation first, so the loop exits knowing it no longer speaks for the
/// connection and deliberately leaves the streams alone.
@Suite("Terminal Drop Stream Tests")
struct TerminalDropStreamTests {
    private func makeConnection(
        socket: MockWebSocketSession,
        autoReconnect: Bool
    ) -> RelayConnection {
        RelayConnection(
            url: URL(string: "wss://relay.example.com")!,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket }),
            config: RelayConnectionConfig(
                connectionTimeout: 0.2, pingInterval: 0.1, autoReconnect: autoReconnect)
        )
    }

    /// Drains `messages` and reports whether it finished before `timeout`.
    private func streamEnds(
        _ messages: AsyncStream<RelayMessage>,
        within timeout: Duration
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in messages {}
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// The keepalive path discards the socket, which retires the generation the receive loop is
    /// running under — so nothing was left to finish the streams and a consumer waited forever.
    @Test("a keepalive drop with auto-reconnect disabled ends the message streams")
    func keepaliveDropEndsStreams() async throws {
        let socket = MockWebSocketSession(defersPing: true)
        let connection = makeConnection(socket: socket, autoReconnect: false)

        let connectTask = Task { try await connection.connect() }
        await socket.waitForPing()
        socket.completePing()
        try await connectTask.value

        let messages = await connection.messages()
        // The keepalive ping is never answered, so it times out and drops the connection.
        #expect(await streamEnds(messages, within: .seconds(3)))
    }

    /// The receive loop's own error path leaves the generation intact, so it still finishes the
    /// streams itself. Pinned so the two paths cannot drift apart again.
    @Test("a transport error with auto-reconnect disabled ends the message streams")
    func transportErrorEndsStreams() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket, autoReconnect: false)
        try await connection.connect()

        let messages = await connection.messages()
        socket.deliver(error: URLError(.networkConnectionLost))

        #expect(await streamEnds(messages, within: .seconds(3)))
    }

    /// With reconnection enabled the streams must survive the drop — they are bound to the
    /// connection, not to one socket.
    @Test("a drop with auto-reconnect enabled keeps the streams open")
    func reconnectingDropKeepsStreams() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket, autoReconnect: true)
        try await connection.connect()

        let messages = await connection.messages()
        socket.deliver(error: URLError(.networkConnectionLost))

        // Still open: a reconnect is pending, so this drop is not terminal.
        #expect(await streamEnds(messages, within: .milliseconds(400)) == false)
        await connection.disconnect()
    }
}
