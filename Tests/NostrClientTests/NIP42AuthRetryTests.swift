import Foundation
import Testing

@testable import NostrClient
@testable import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-42 Auth-Required Retry Tests")
struct NIP42AuthRetryTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeConnection(publishAckTimeout: TimeInterval = 5) -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            config: RelayConnectionConfig(
                connectionTimeout: 1,
                publishAckTimeout: publishAckTimeout,
                pingInterval: 60,
                autoReconnect: false
            )
        )
        return (connection, mock)
    }

    private func makeResponder(signer: EventSigner) -> RelayConnection.AuthenticationResponder {
        { relayURL, challenge in
            try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }
    }

    private func eventFrames(in mock: MockWebSocketSession) -> [String] {
        mock.sentTextFrames.filter { $0.hasPrefix("[\"EVENT\"") }
    }

    private func requestFrames(in mock: MockWebSocketSession) -> [String] {
        mock.sentTextFrames.filter { $0.hasPrefix("[\"REQ\"") }
    }

    // MARK: - Publish Retry

    @Test("publish retries once after the automatic authentication succeeds")
    func publishRetriesAfterAuthentication() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        let note = try signer.signTextNote(content: "gm")
        let publishTask = Task { try await connection.publish(note) }

        // First attempt is rejected; the relay sends the challenge alongside.
        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 1 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",false,\"auth-required: we only serve registered users\"]"))
        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        // The responder answers, the relay accepts the AUTH...
        try await NIP42TestSupport.acknowledgeAuth(on: connection, mock: mock)

        // ...and the publish resends the same event, which now succeeds.
        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 2 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",true,\"\"]"))

        try await publishTask.value
        #expect(eventFrames(in: mock).count == 2)
        await connection.disconnect()
    }

    @Test("publish does not retry when nothing can authenticate")
    func publishFailsWithoutAuthenticationPath() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: try KeyPair())
        let note = try signer.signTextNote(content: "gm")
        let publishTask = Task { try await connection.publish(note) }

        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 1 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",false,\"auth-required: we only serve registered users\"]"))

        await #expect(
            throws: NostrError.relayError(
                "Relay rejected event \(note.id): auth-required: we only serve registered users")
        ) {
            try await publishTask.value
        }
        #expect(eventFrames(in: mock).count == 1)
        await connection.disconnect()
    }

    @Test("publish surfaces the authentication failure when the AUTH is rejected")
    func publishSurfacesRejectedAuthentication() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        let note = try signer.signTextNote(content: "gm")
        let publishTask = Task { try await connection.publish(note) }

        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 1 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",false,\"auth-required: we only serve registered users\"]"))

        // Hold the challenge back until the rejected publish is parked on the
        // authentication outcome — otherwise the AUTH rejection can settle
        // before the waiter registers and the publish would (correctly) fall
        // back to the original rejection instead.
        try await NIP42TestSupport.pollUntil { await connection.authenticationWaiterCount > 0 }
        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        try await NIP42TestSupport.pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let auth = try NIP42TestSupport.sentAuthEvent(in: mock)
        mock.deliver(.string("[\"OK\",\"\(auth.id)\",false,\"restricted: pubkey not on whitelist\"]"))

        await #expect(throws: NostrError.authenticationFailed("restricted: pubkey not on whitelist")) {
            try await publishTask.value
        }
        #expect(eventFrames(in: mock).count == 1)
        await connection.disconnect()
    }

    @Test("publish falls back to the original rejection when no authentication concludes")
    func publishTimesOutWaitingForAuthentication() async throws {
        let (connection, mock) = makeConnection(publishAckTimeout: 0.1)
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        let note = try signer.signTextNote(content: "gm")
        let publishTask = Task { try await connection.publish(note) }

        // The relay rejects but never sends a challenge, so the responder
        // never fires and the wait for authentication times out.
        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 1 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",false,\"auth-required: we only serve registered users\"]"))

        await #expect(
            throws: NostrError.relayError(
                "Relay rejected event \(note.id): auth-required: we only serve registered users")
        ) {
            try await publishTask.value
        }
        #expect(eventFrames(in: mock).count == 1)
        await connection.disconnect()
    }

    @Test("non-auth rejections keep failing without a retry")
    func publishDoesNotRetryOtherRejections() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        let note = try signer.signTextNote(content: "gm")
        let publishTask = Task { try await connection.publish(note) }

        try await NIP42TestSupport.pollUntil { self.eventFrames(in: mock).count == 1 }
        mock.deliver(.string("[\"OK\",\"\(note.id)\",false,\"blocked: you are banned\"]"))

        await #expect(
            throws: NostrError.relayError("Relay rejected event \(note.id): blocked: you are banned")
        ) {
            try await publishTask.value
        }
        #expect(eventFrames(in: mock).count == 1)
        await connection.disconnect()
    }

    // MARK: - Responder In-Flight Guard

    @Test("reinstalling a responder while an answer is in flight sends no second AUTH")
    func responderReinstallDoesNotDoubleAnswer() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        let slowResponder: RelayConnection.AuthenticationResponder = { relayURL, challenge in
            // Slow enough that the reinstall below happens while this answer
            // is still being produced — before authenticate(with:) registers
            // its pending entry.
            try? await Task.sleep(for: .milliseconds(100))
            return try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }
        await connection.setAuthenticationResponder(slowResponder)
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await NIP42TestSupport.pollUntil { await connection.authenticationChallenge != nil }

        // The first answer is suspended inside the responder; reinstalling must
        // not start a second one for the same challenge.
        await connection.setAuthenticationResponder(slowResponder)

        try await NIP42TestSupport.pollUntil {
            mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") }
        }
        // Allow a would-be duplicate answer time to land before counting.
        try await Task.sleep(for: .milliseconds(150))
        #expect(mock.sentTextFrames.filter { $0.hasPrefix("[\"AUTH\"") }.count == 1)
        await connection.disconnect()
    }

    // MARK: - Subscription Re-Request

    @Test("a subscription closed with auth-required is re-requested after authentication")
    func subscriptionReRequestedAfterAuthentication() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        try await connection.subscribe(subscriptionId: "sub-1", filters: [Filter(kinds: [4])])
        #expect(requestFrames(in: mock).count == 1)

        mock.deliver(.string(#"["CLOSED","sub-1","auth-required: we can't serve DMs to unauthenticated users"]"#))
        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        try await NIP42TestSupport.acknowledgeAuth(on: connection, mock: mock)

        try await NIP42TestSupport.pollUntil { self.requestFrames(in: mock).count == 2 }
        #expect(requestFrames(in: mock).last?.contains("sub-1") == true)
        await connection.disconnect()
    }

    @Test("a subscription closed for other reasons is not re-requested")
    func subscriptionClosedForOtherReasonsStaysClosed() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        try await connection.subscribe(subscriptionId: "sub-1", filters: [Filter(kinds: [4])])
        mock.deliver(.string(#"["CLOSED","sub-1","error: shutting down idle subscription"]"#))
        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        try await NIP42TestSupport.acknowledgeAuth(on: connection, mock: mock)

        try await Task.sleep(for: .milliseconds(50))
        #expect(requestFrames(in: mock).count == 1)
        await connection.disconnect()
    }

    @Test("a subscription unsubscribed while awaiting auth is not re-requested")
    func unsubscribedSubscriptionIsNotReRequested() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder(makeResponder(signer: signer))
        try await connection.connect()

        try await connection.subscribe(subscriptionId: "sub-1", filters: [Filter(kinds: [4])])

        // Iterate messages() to know the CLOSED frame has been processed — the
        // yield happens after the receive loop marked the subscription — so the
        // unsubscribe below deterministically races *after* the marking.
        let messages = await connection.messages()
        mock.deliver(.string(#"["CLOSED","sub-1","auth-required: only for registered users"]"#))
        var iterator = messages.makeAsyncIterator()
        _ = await iterator.next()

        try await connection.unsubscribe(subscriptionId: "sub-1")

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await NIP42TestSupport.acknowledgeAuth(on: connection, mock: mock)

        try await Task.sleep(for: .milliseconds(50))
        #expect(requestFrames(in: mock).count == 1)
        await connection.disconnect()
    }
}
