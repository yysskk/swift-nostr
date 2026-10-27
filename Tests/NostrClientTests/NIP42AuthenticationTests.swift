import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-42 Authentication Event Tests")
struct NIP42AuthenticationEventTests {

    @Test("relay tag carries the relay URL in canonical form")
    func relayTag() throws {
        #expect(
            Tag.relay(try RelayURL(string: "wss://Relay.Example.com/")).rawArray == [
                "relay", "wss://relay.example.com",
            ])
    }

    @Test("challenge tag carries the challenge string")
    func challengeTag() {
        #expect(Tag.challenge("challengestringhere").rawArray == ["challenge", "challengestringhere"])
    }

    @Test("a signed client authentication event is a valid kind-22242 event")
    func signedClientAuthentication() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let relayURL = RelayURL("wss://relay.example.com")!

        let event = signer.sign(.clientAuthentication(relayURL: relayURL, challenge: "challengestringhere"))

        #expect(event.kind == .clientAuthentication)
        #expect(event.publicKey == signer.publicKey)
        #expect(event.firstTagValue(named: "relay") == "wss://relay.example.com")
        #expect(event.firstTagValue(named: "challenge") == "challengestringhere")
        #expect(event.content.isEmpty)
        try event.verify()
    }

    @Test("clientAuthentication timestamps the event with the current time")
    func clientAuthenticationTimestamp() throws {
        let signer = EventSigner(keyPair: KeyPair())

        let event = signer.sign(
            .clientAuthentication(
                relayURL: RelayURL("wss://relay.example.com")!,
                challenge: "abc"
            ))

        // NIP-42 requires created_at to be close to the current time; relays
        // typically tolerate ~10 minutes of skew.
        let now = Timestamp.now
        #expect(abs(event.createdAt.rawValue - now.rawValue) < 60)
    }

    @Test("the relay tag is the URL the connection opens")
    func relayTagMatchesConnectionURL() throws {
        let signer = EventSigner(keyPair: KeyPair())

        // NIP-42 says the relay tag is the URL "as used to connect". A connection opens its
        // relay URL's canonical form, so every spelling of the relay yields that same tag.
        let connection = RelayConnection(url: try RelayURL(string: "WSS://Relay.Example.com/"))
        let event = signer.sign(.clientAuthentication(relayURL: connection.url, challenge: "abc"))
        #expect(event.firstTagValue(named: "relay") == connection.url.url.absoluteString)
        #expect(event.firstTagValue(named: "relay") == "wss://relay.example.com")
    }

    @Test("an authentication event must not be published")
    func authenticationEventCannotBePublished() async throws {
        let pool = RelayPool()
        await pool.addRelay(RelayURL("wss://relay.example.com")!)
        let signer = EventSigner(keyPair: KeyPair())
        let authEvent = signer.sign(
            .clientAuthentication(
                relayURL: RelayURL("wss://relay.example.com")!, challenge: "abc"))

        await #expect(throws: RelayPool.Error.cannotPublishAuthenticationEvent) {
            _ = try await pool.publish(authEvent)
        }
    }
}

@Suite("NIP-42 Relay Connection Authentication Tests")
struct NIP42RelayConnectionTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    private func makeConnection(publishAckTimeout: Duration = .seconds(30)) -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            // No auto-reconnect and a long ping interval keep the test's background
            // tasks inert; the connection is torn down explicitly at the end.
            config: RelayConnectionConfig(
                connectionTimeout: .seconds(1),
                publishAckTimeout: publishAckTimeout,
                pingInterval: .seconds(60),
                autoReconnect: false
            )
        )
        return (connection, mock)
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RelayConnection.Error.timedOut
    }

    private func signedAuthEvent(signer: EventSigner, challenge: String = "challengestringhere") throws -> Event {
        signer.sign(.clientAuthentication(relayURL: relayURL, challenge: challenge))
    }

    /// Extracts the event from the first AUTH frame the connection sent.
    private func sentAuthEvent(in mock: MockWebSocketSession) throws -> Event {
        guard let frame = mock.sentTextFrames.first(where: { $0.hasPrefix("[\"AUTH\"") }),
            case .auth(let event) = try parseClientFrame(frame)
        else {
            throw RelayMessage.Error.malformed
        }
        return event
    }

    /// Parses a serialized client frame back into a ClientMessage (AUTH only).
    private func parseClientFrame(_ text: String) throws -> ClientMessage {
        guard let data = text.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            array.first as? String == "AUTH",
            let eventDict = array[1] as? [String: Any]
        else {
            throw RelayMessage.Error.malformed
        }
        let eventData = try JSONSerialization.data(withJSONObject: eventDict)
        return .auth(try JSONDecoder().decode(Event.self, from: eventData))
    }

    @Test("AUTH challenge from the relay is stored on the connection")
    func challengeIsStored() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        try await pollUntil { await connection.authenticationChallenge == "challengestringhere" }
        await connection.disconnect()
    }

    @Test("a newer AUTH challenge replaces the previous one")
    func newerChallengeReplacesOld() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","first"]"#))
        try await pollUntil { await connection.authenticationChallenge == "first" }

        mock.deliver(.string(#"["AUTH","second"]"#))
        try await pollUntil { await connection.authenticationChallenge == "second" }
        await connection.disconnect()
    }

    @Test("authenticate sends an AUTH frame and resolves on OK true")
    func authenticateResolvesOnOK() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())
        let event = try signedAuthEvent(signer: signer)

        let authTask = Task { try await connection.authenticate(with: event) }

        // Deliver the OK only once the AUTH frame has been sent, so the waiter
        // is registered when the acknowledgment arrives.
        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"AUTH\"") && $0.contains(event.id.hex) } }
        mock.deliver(.string("[\"OK\",\"\(event.id)\",true,\"\"]"))

        try await authTask.value
        #expect(await connection.authenticatedPublicKeys == [signer.publicKey])
        #expect(await connection.isAuthenticated)
        await connection.disconnect()
    }

    @Test("authenticate surfaces the relay's rejection message")
    func authenticateThrowsOnRejection() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())
        let event = try signedAuthEvent(signer: signer)

        let authTask = Task { try await connection.authenticate(with: event) }

        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"AUTH\"") } }
        mock.deliver(.string("[\"OK\",\"\(event.id)\",false,\"restricted: not allowed\"]"))

        await #expect(
            throws: RelayConnection.Error.authenticationRejected(
                RelayRejection(prefix: .restricted, message: "not allowed"))
        ) {
            try await authTask.value
        }
        #expect(await connection.isAuthenticated == false)
        await connection.disconnect()
    }

    @Test("authenticate rejects events that are not kind 22242")
    func authenticateRejectsWrongKind() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())
        let note = signer.sign(.textNote("not an auth event"))

        await #expect(throws: RelayConnection.Error.invalidAuthenticationEventKind(.textNote)) {
            try await connection.authenticate(with: note)
        }
        #expect(!mock.sentTextFrames.contains { $0.contains("\"AUTH\"") })
        await connection.disconnect()
    }

    @Test("authenticate requires an established connection")
    func authenticateRequiresConnection() async throws {
        let (connection, _) = makeConnection()

        let signer = EventSigner(keyPair: KeyPair())
        let event = try signedAuthEvent(signer: signer)

        await #expect(throws: RelayConnection.Error.notConnected) {
            try await connection.authenticate(with: event)
        }
    }

    @Test("authenticate(using:) answers the stored challenge")
    func authenticateUsingSignerAnswersChallenge() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        let signer = EventSigner(keyPair: KeyPair())
        let authTask = Task { try await connection.authenticate(using: signer) }

        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"AUTH\"") } }
        let sent = try sentAuthEvent(in: mock)
        #expect(sent.kind == .clientAuthentication)
        #expect(sent.publicKey == signer.publicKey)
        #expect(sent.firstTagValue(named: "relay") == relayURL.description)
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        try sent.verify()

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))

        try await authTask.value
        #expect(await connection.isAuthenticated)
        await connection.disconnect()
    }

    @Test("authenticate(using:) answers the stored challenge with a signer that is not an EventSigner")
    func authenticateUsingRemoteSignerAnswersChallenge() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        let keyPair = KeyPair()
        let authTask = Task { try await connection.authenticate(using: StubRemoteSigner(keyPair: keyPair)) }

        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"AUTH\"") } }
        let sent = try sentAuthEvent(in: mock)
        #expect(sent.publicKey == keyPair.publicKey)
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        try sent.verify()

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))

        try await authTask.value
        #expect(await connection.authenticatedPublicKeys.contains(keyPair.publicKey))
        await connection.disconnect()
    }

    @Test("authenticate(using:) fails when the relay has not sent a challenge")
    func authenticateUsingSignerRequiresChallenge() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())

        await #expect(throws: RelayConnection.Error.missingAuthenticationChallenge) {
            try await connection.authenticate(using: signer)
        }
        #expect(!mock.sentTextFrames.contains { $0.contains("\"AUTH\"") })
        await connection.disconnect()
    }

    @Test("multiple public keys can authenticate on one connection")
    func multiplePublicKeysAuthenticate() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let alice = EventSigner(keyPair: KeyPair())
        let bob = EventSigner(keyPair: KeyPair())

        for signer in [alice, bob] {
            let event = try signedAuthEvent(signer: signer)
            let authTask = Task { try await connection.authenticate(with: event) }
            try await pollUntil { mock.sentTextFrames.contains { $0.contains(event.id.hex) } }
            mock.deliver(.string("[\"OK\",\"\(event.id)\",true,\"\"]"))
            try await authTask.value
        }

        #expect(await connection.authenticatedPublicKeys == [alice.publicKey, bob.publicKey])
        await connection.disconnect()
    }

    @Test("a late OK after a timed-out authenticate does not authenticate")
    func lateOKAfterTimeoutDoesNotAuthenticate() async throws {
        let (connection, mock) = makeConnection(publishAckTimeout: .milliseconds(50))
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())
        let event = try signedAuthEvent(signer: signer)

        await #expect(throws: RelayConnection.Error.timedOut) {
            try await connection.authenticate(with: event)
        }

        // The relay answers only after the caller already saw the failure.
        mock.deliver(.string("[\"OK\",\"\(event.id)\",true,\"\"]"))
        try await Task.sleep(for: .milliseconds(50))

        #expect(await connection.isAuthenticated == false)
        await connection.disconnect()
    }

    @Test("disconnect clears the challenge and authenticated public keys")
    func disconnectClearsAuthenticationState() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        let signer = EventSigner(keyPair: KeyPair())
        let event = try signedAuthEvent(signer: signer)
        let authTask = Task { try await connection.authenticate(with: event) }
        try await pollUntil { mock.sentTextFrames.contains { $0.contains(event.id.hex) } }
        mock.deliver(.string("[\"OK\",\"\(event.id)\",true,\"\"]"))
        try await authTask.value

        await connection.disconnect()

        #expect(await connection.authenticationChallenge == nil)
        #expect(await connection.authenticatedPublicKeys.isEmpty)
        #expect(await connection.isAuthenticated == false)
    }

    @Test("publish rejection still surfaces the relay rejection")
    func publishRejectionSurfacesRelayError() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.textNote("gm"))

        let publishTask = Task { try await connection.publish(event) }

        try await pollUntil { mock.sentTextFrames.contains { $0.contains("\"EVENT\"") } }
        mock.deliver(.string("[\"OK\",\"\(event.id)\",false,\"blocked: you are banned\"]"))

        await #expect(
            throws: RelayRejection(prefix: .blocked, message: "you are banned")
        ) {
            try await publishTask.value
        }
        await connection.disconnect()
    }
}
