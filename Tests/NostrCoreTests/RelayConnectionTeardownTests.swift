import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// `.failed` is where a connection sits after any dropped connection, so it is the state
/// `disconnect()` is most often called from. Skipping the teardown there left the connection
/// carrying the previous session's debris: callers blocked on acknowledgements that would never
/// come, subscriptions ready to be replayed, and NIP-42 state describing a session that was gone.
@Suite("Relay Connection Teardown Tests")
struct RelayConnectionTeardownTests {
    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeConnection(socket: MockWebSocketSession) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket }),
            config: RelayConnectionConfig(publishAckTimeout: 30, autoReconnect: false)
        )
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// Drops the transport so the receive loop fails and the connection lands in `.failed`.
    private func failConnection(_ connection: RelayConnection, socket: MockWebSocketSession) async throws {
        socket.deliver(error: URLError(.networkConnectionLost))
        try await pollUntil { await connection.state != .connected }
    }

    /// A publish waits for the relay's OK. Torn down from `.failed`, that waiter was left in place
    /// and the caller blocked for the full 30-second ack timeout on a connection already gone.
    @Test("disconnecting from failed fails in-flight publish waiters")
    func disconnectFromFailedFailsPublishWaiters() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signTextNote(content: "hello")

        let publish = Task { try await connection.publish(event) }
        // Wait for the EVENT to reach the socket, so the waiter is registered before the drop.
        try await pollUntil { socket.sentTextFrames.contains { $0.contains(event.id) } }

        try await failConnection(connection, socket: socket)
        await connection.disconnect()

        await #expect(throws: NostrError.notConnected) { try await publish.value }
    }

    @Test("disconnecting from failed clears tracked subscriptions")
    func disconnectFromFailedClearsSubscriptions() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()
        try await connection.subscribe(subscriptionId: "sub1", filters: [Filter(kinds: [1])])

        #expect(await connection.subscriptions.keys.contains("sub1"))

        try await failConnection(connection, socket: socket)
        await connection.disconnect()

        // Left in place, these would be replayed to the relay on the next connect — resurrecting
        // subscriptions the caller believes are gone.
        #expect(await connection.subscriptions.isEmpty)
    }

    /// NIP-42 authentication is scoped to one socket. Retained after teardown, `isAuthenticated`
    /// answered for a session that no longer existed.
    @Test("disconnecting from failed clears NIP-42 session state")
    func disconnectFromFailedClearsAuthentication() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let signer = EventSigner(keyPair: try KeyPair())
        socket.deliver(.string(#"["AUTH","challenge"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        let authenticate = Task { try await connection.authenticate(using: signer) }
        try await pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }

        let authEventID = try #require(Self.authEventID(in: socket))
        socket.deliver(.string(#"["OK","\#(authEventID)",true,""]"#))
        try await authenticate.value

        #expect(await connection.isAuthenticated)

        try await failConnection(connection, socket: socket)
        await connection.disconnect()

        #expect(await !connection.isAuthenticated)
        #expect(await connection.authenticationChallenge == nil)
    }

    /// `stateChanges()` describes transitions, so a disconnect that changes nothing should not
    /// announce one.
    @Test("disconnecting an already-disconnected connection announces nothing further")
    func disconnectingTwiceAnnouncesOneTransition() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let states = await connection.stateChanges()
        await connection.disconnect()
        await connection.disconnect()

        // The stream replays the current state first, then the transitions.
        var seen: [RelayConnectionState] = []
        for await state in states {
            seen.append(state)
            if seen.count >= 3 { break }
        }

        #expect(seen == [.connected, .disconnecting, .disconnected])
    }

    /// Registering a stream and then connecting is the normal order, so a stream taken while
    /// disconnected must wait for the next session rather than finishing immediately.
    @Test("a stream taken while disconnected delivers from the next session")
    func streamTakenWhileDisconnectedDelivers() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)

        let messages = await connection.messages()
        try await connection.connect()

        socket.deliver(.string(#"["NOTICE","hello"]"#))

        var received: RelayMessage?
        for await message in messages {
            received = message
            break
        }

        guard case .notice(let text) = received else {
            Issue.record("expected a notice, got \(String(describing: received))")
            return
        }
        #expect(text == "hello")

        await connection.disconnect()
    }

    /// The id of the event in the first AUTH frame the connection sent.
    private static func authEventID(in socket: MockWebSocketSession) -> String? {
        for text in socket.sentTextFrames {
            guard let data = text.data(using: .utf8),
                let frame = try? JSONSerialization.jsonObject(with: data) as? [Any],
                frame.first as? String == "AUTH",
                let event = frame.dropFirst().first as? [String: Any]
            else { continue }
            return event["id"] as? String
        }
        return nil
    }
}
