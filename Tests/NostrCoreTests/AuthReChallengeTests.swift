import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// A relay may send AUTH more than once — on reconnect, on a policy change, or simply because it
/// re-challenges. `setAuthenticationResponder` already refused to start an answer while one was in
/// flight or an authentication was established; the receive loop answered every frame regardless.
@Suite("NIP-42 Re-challenge Tests")
struct AuthReChallengeTests {
    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeConnection(socket: MockWebSocketSession) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket }),
            config: RelayConnectionConfig(autoReconnect: false)
        )
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    private static func authFrameCount(in socket: MockWebSocketSession) -> Int {
        socket.sentTextFrames.filter { $0.hasPrefix("[\"AUTH\"") }.count
    }

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

    /// Repeated challenges arriving before the first answer completes must not each start their own
    /// answer: `isAnsweringChallenge` is a single flag, so the first to finish clears it for all.
    @Test("repeated challenges while answering produce one AUTH")
    func repeatedChallengesWhileAnsweringProduceOneAuth() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder { url, challenge in
            try? signer.signClientAuthentication(relayURL: url, challenge: challenge)
        }

        for index in 0..<5 {
            socket.deliver(.string(#"["AUTH","challenge-\#(index)"]"#))
        }

        try await pollUntil { Self.authFrameCount(in: socket) >= 1 }
        // Give any extra answers the same chance to arrive as the first one had.
        try await Task.sleep(for: .milliseconds(50))

        #expect(Self.authFrameCount(in: socket) == 1)
        await connection.disconnect()
    }

    /// Once the session is authenticated, a further challenge is redundant — answering it would
    /// re-sign and re-send for a session that already has what it needs.
    @Test("a challenge after authenticating is not answered again")
    func challengeAfterAuthenticatingIsIgnored() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder { url, challenge in
            try? signer.signClientAuthentication(relayURL: url, challenge: challenge)
        }

        socket.deliver(.string(#"["AUTH","first"]"#))
        try await pollUntil { Self.authFrameCount(in: socket) >= 1 }

        let eventID = try #require(Self.authEventID(in: socket))
        socket.deliver(.string(#"["OK","\#(eventID)",true,""]"#))
        try await pollUntil { await connection.isAuthenticated }

        socket.deliver(.string(#"["AUTH","second"]"#))
        try await Task.sleep(for: .milliseconds(50))

        #expect(Self.authFrameCount(in: socket) == 1)
        await connection.disconnect()
    }

    /// The challenge is still recorded, so a caller installing a responder later — or a session
    /// that loses its authentication — has the latest one to answer.
    @Test("a re-challenge still updates the stored challenge")
    func reChallengeUpdatesStoredChallenge() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        socket.deliver(.string(#"["AUTH","first"]"#))
        try await pollUntil { await connection.authenticationChallenge == "first" }

        socket.deliver(.string(#"["AUTH","second"]"#))
        try await pollUntil { await connection.authenticationChallenge == "second" }

        await connection.disconnect()
    }
}
