import Foundation
import NostrCore
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NIP-42 Automatic Authentication Tests")
struct NIP42AutomaticAuthenticationTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    private func makeConnection() -> (RelayConnection, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let connection = RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock }),
            config: noReconnectConfig
        )
        return (connection, mock)
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// Extracts the event of the first sent AUTH frame.
    private func sentAuthEvent(in mock: MockWebSocketSession) throws -> Event {
        guard let frame = mock.sentTextFrames.first(where: { $0.hasPrefix("[\"AUTH\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let eventDict = array[1] as? [String: Any]
        else {
            throw NostrError.invalidMessageFormat
        }
        let eventData = try JSONSerialization.data(withJSONObject: eventDict)
        return try JSONDecoder().decode(Event.self, from: eventData)
    }

    /// Delivers the OK for the next AUTH frame the connection sends, then
    /// waits for the pubkey to be recorded as authenticated.
    private func acknowledgeAuth(
        on connection: RelayConnection, mock: MockWebSocketSession
    ) async throws -> Event {
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try sentAuthEvent(in: mock)
        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await pollUntil { await connection.isAuthenticated }
        return sent
    }

    // MARK: - RelayConnection

    @Test("a responder answers AUTH challenges automatically")
    func responderAnswersChallenge() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder { relayURL, challenge in
            try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        let sent = try await acknowledgeAuth(on: connection, mock: mock)
        #expect(sent.kind == .clientAuthentication)
        #expect(sent.pubkey == signer.publicKey)
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        #expect(await connection.authenticatedPubkeys == [signer.publicKey])
        await connection.disconnect()
    }

    @Test("a responder returning nil leaves the challenge unanswered")
    func responderDeclines() async throws {
        let (connection, mock) = makeConnection()
        await connection.setAuthenticationResponder { _, _ in nil }
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        // Give a would-be authentication task a chance to run before asserting.
        try await Task.sleep(for: .milliseconds(50))
        #expect(!mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") })
        await connection.disconnect()
    }

    @Test("installing a responder answers an already-stored challenge")
    func responderAnswersStoredChallenge() async throws {
        let (connection, mock) = makeConnection()
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder { relayURL, challenge in
            try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }

        let sent = try await acknowledgeAuth(on: connection, mock: mock)
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        await connection.disconnect()
    }

    @Test("clearing the responder stops automatic answers")
    func clearedResponderDoesNotAnswer() async throws {
        let (connection, mock) = makeConnection()
        let signer = EventSigner(keyPair: try KeyPair())
        await connection.setAuthenticationResponder { relayURL, challenge in
            try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }
        await connection.setAuthenticationResponder(nil)
        try await connection.connect()

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        try await pollUntil { await connection.authenticationChallenge != nil }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") })
        await connection.disconnect()
    }

    // MARK: - RelayPool

    @Test("the pool responder reaches relays added before and after it is set")
    func poolResponderAppliesToAllRelays() async throws {
        let mockA = MockWebSocketSession()
        let mockB = MockWebSocketSession()
        let mocks = [mockA, mockB]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mocks[counter.next()] })
        )
        let signer = EventSigner(keyPair: try KeyPair())

        let urlA = URL(string: "wss://relay-a.example.com")!
        let urlB = URL(string: "wss://relay-b.example.com")!

        let connectionA = await pool.addRelay(url: urlA)
        await pool.setAuthenticationResponder { relayURL, challenge in
            try? signer.signClientAuthentication(relayURL: relayURL, challenge: challenge)
        }
        let connectionB = await pool.addRelay(url: urlB)
        // Connect sequentially so the factory pairs mockA with relay A and
        // mockB with relay B deterministically.
        try await connectionA.connect()
        try await connectionB.connect()

        mockA.deliver(.string(#"["AUTH","challenge-a"]"#))
        mockB.deliver(.string(#"["AUTH","challenge-b"]"#))

        for (mock, url) in [(mockA, urlA), (mockB, urlB)] {
            let connection = try #require(await pool.relay(for: url))
            let sent = try await acknowledgeAuth(on: connection, mock: mock)
            #expect(sent.firstTagValue(named: "relay") == url.absoluteString)
        }
        await pool.disconnectAll()
    }

    // MARK: - NostrClient

    private func makeClient() -> (NostrClient, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        return (NostrClient(relayPool: pool), mock)
    }

    @Test("with a signer set, the client answers challenges automatically by default")
    func clientAutomaticByDefault() async throws {
        let (client, mock) = makeClient()
        let keyPair = try KeyPair()
        await client.setSigner(EventSigner(keyPair: keyPair))
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))

        let connection = try #require(await client.relayPool.relay(for: relayURL))
        let sent = try await acknowledgeAuth(on: connection, mock: mock)
        #expect(sent.pubkey == keyPair.publicKeyHex)
        #expect(sent.firstTagValue(named: "relay") == relayURL.absoluteString)
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        await client.disconnect()
    }

    @Test("a signer set before relays are added still answers their challenges")
    func clientSignerBeforeRelays() async throws {
        let (client, mock) = makeClient()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","early-signer"]"#))

        let connection = try #require(await client.relayPool.relay(for: relayURL))
        let sent = try await acknowledgeAuth(on: connection, mock: mock)
        #expect(sent.firstTagValue(named: "challenge") == "early-signer")
        await client.disconnect()
    }

    @Test("manual mode does not answer challenges until authenticate is called")
    func clientManualMode() async throws {
        let (client, mock) = makeClient()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))
        await client.setAuthenticationMode(.manual)
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") })

        async let authentication: Void = client.authenticate(relayURL: relayURL)
        let sent = try await acknowledgeAuth(on: connection, mock: mock)
        try await authentication
        #expect(sent.firstTagValue(named: "challenge") == "challengestringhere")
        #expect(await connection.isAuthenticated)
        await client.disconnect()
    }

    @Test("switching back to automatic answers a pending challenge")
    func clientSwitchToAutomaticAnswersPendingChallenge() async throws {
        let (client, mock) = makeClient()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))
        await client.setAuthenticationMode(.manual)
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        await client.setAuthenticationMode(.automatic)

        _ = try await acknowledgeAuth(on: connection, mock: mock)
        await client.disconnect()
    }

    @Test("authenticate(relayURL:) requires the relay to be in the pool")
    func clientAuthenticateUnknownRelay() async throws {
        let (client, _) = makeClient()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))

        await #expect(throws: NostrError.self) {
            try await client.authenticate(relayURL: URL(string: "wss://unknown.example.com")!)
        }
    }

    @Test("authenticate(relayURL:) requires a challenge")
    func clientAuthenticateWithoutChallenge() async throws {
        let (client, _) = makeClient()
        await client.setSigner(EventSigner(keyPair: try KeyPair()))
        try await client.connect(to: [relayURL.absoluteString])

        await #expect(throws: NostrError.authenticationFailed("The relay has not sent an AUTH challenge")) {
            try await client.authenticate(relayURL: relayURL)
        }
        await client.disconnect()
    }

    @Test("authenticate(relayURL:) requires a signer")
    func clientAuthenticateWithoutSigner() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        await #expect(throws: NostrError.signerNotSet) {
            try await client.authenticate(relayURL: relayURL)
        }
        await client.disconnect()
    }

    @Test("without a signer, challenges go unanswered")
    func clientWithoutSignerDoesNotAnswer() async throws {
        let (client, mock) = makeClient()
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","challengestringhere"]"#))
        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        try await Task.sleep(for: .milliseconds(50))
        #expect(!mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") })
        await client.disconnect()
    }
}

/// Hands out incrementing indexes to a factory closure that must stay `@Sendable`.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
