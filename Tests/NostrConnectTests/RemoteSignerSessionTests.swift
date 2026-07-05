import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Session Tests")
struct RemoteSignerSessionTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = try KeyPair()
        self.signer = try KeyPair()
    }

    private func makeSigner(
        secret: String? = nil, transport: FakeRemoteSignerTransport, requestTimeout: TimeInterval = 1
    ) throws -> RemoteSigner {
        try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer, secret: secret),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: requestTimeout))
    }

    // MARK: - connect handshake

    @Test("connect sends a kind-24133 connect request p-tagging the signer")
    func connectSendsRequest() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        async let connect: Void = remote.connect()

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let event = sent[0]
        #expect(event.kind == .nostrConnect)
        #expect(event.pubkey == client.publicKeyHex)
        #expect(event.firstTagValue(named: "p") == signer.publicKeyHex)

        let request = try RemoteSignerFixtures.decryptRequest(event, client: client, signer: signer)
        #expect(request.method == RemoteSignerMethod.connect.rawValue)
        #expect(request.params == [signer.publicKeyHex])

        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        try await connect
        #expect(await remote.isConnectedForTesting == true)
    }

    @Test("connect presents the bunker secret when the token carries one")
    func connectPresentsSecret() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cr3t", transport: transport)

        async let connect: Void = remote.connect()

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        #expect(request.params == [signer.publicKeyHex, "s3cr3t"])

        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        try await connect
    }

    @Test("connect accepts a signer that echoes the secret instead of ack")
    func connectAcceptsEchoedSecret() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "echo-me", transport: transport)

        async let connect: Void = remote.connect()

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "echo-me", client: client, signer: signer))
        try await connect
    }

    @Test("connect throws connectionRejected on an unexpected result")
    func connectRejected() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        let connect = Task { try await remote.connect() }

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "nope", client: client, signer: signer))

        await #expect(throws: RemoteSignerError.connectionRejected(message: "nope")) {
            try await connect.value
        }
    }

    // MARK: - correlation by id

    @Test("concurrent requests resolve with their own responses, matched by id")
    func concurrentRequestsCorrelateByID() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        try await connectHandshake(remote, transport: transport)

        let pubkey = Task { try await remote.userPublicKey() }
        let pong = Task { try await remote.ping() }

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 3)
        // The two commands are events 2 and 3 (event 1 was the connect request).
        let requests = try sent.dropFirst().map {
            try RemoteSignerFixtures.decryptRequest($0, client: client, signer: signer)
        }
        #expect(Set(requests.map(\.id)).count == 2)

        // Answer them out of order to prove correlation is by id, not arrival order.
        for request in requests.reversed() {
            let result = request.method == RemoteSignerMethod.ping.rawValue ? "pong" : "userpub"
            try await transport.deliver(
                RemoteSignerFixtures.response(
                    requestID: request.id, result: result, client: client, signer: signer))
        }

        let resolved = try await pubkey.value
        #expect(resolved == "userpub")
        try await pong.value
    }

    @Test("a response with an unknown id is ignored")
    func unknownIDIgnored() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: 0.3)
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // A stray response for a different id must not resolve the pending ping.
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "unknown-id", result: "pong", client: client, signer: signer))
        await #expect(throws: RemoteSignerError.timedOut) { try await ping.value }
        _ = request
    }

    @Test("a response from a non-signer pubkey is ignored")
    func nonSignerResponseIgnored() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: 0.3)
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // A response encrypted by a different keypair, authored by an impostor, must be dropped.
        let impostor = try KeyPair()
        let json = "{\"id\":\"\(request.id)\",\"result\":\"pong\"}"
        let sealed = try SealedMessage.seal(json, for: client.publicKeyHex, using: impostor)
        let forged = Event(
            id: "forged", pubkey: impostor.publicKeyHex, createdAt: 0, kind: .nostrConnect,
            tags: [["p", client.publicKeyHex]], content: sealed.payload, sig: "")
        await transport.deliver(forged)

        await #expect(throws: RemoteSignerError.timedOut) { try await ping.value }
    }

    // MARK: - timeout

    @Test("a request with no response times out")
    func requestTimesOut() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: 0.2)
        try await connectHandshake(remote, transport: transport)

        await #expect(throws: RemoteSignerError.timedOut) {
            try await remote.ping()
        }
    }

    // MARK: - error response

    @Test("an error response surfaces as signerError")
    func errorResponse() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, error: "boom", client: client, signer: signer))

        await #expect(throws: RemoteSignerError.signerError(message: "boom")) { try await ping.value }
    }

    // MARK: - auth_url flow

    @Test("an auth_url challenge is emitted, keeps the request pending, and the real response completes it")
    func authChallengeFlow() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: 0.3, authChallengeTimeout: 2))
        try await connectHandshake(remote, transport: transport)

        let challenges = await remote.authChallenges()

        let pubkey = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // First the signer answers with an auth challenge for the same id.
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "auth_url", error: "https://auth.example",
                client: client, signer: signer))

        var iterator = challenges.makeAsyncIterator()
        let challenge = await iterator.next()
        #expect(challenge?.url == URL(string: "https://auth.example"))
        #expect(challenge?.method == .getPublicKey)
        #expect(challenge?.requestID == request.id)

        // The request stays pending past the short requestTimeout; wait beyond it, then deliver the
        // real response and confirm it completes.
        try await Task.sleep(for: .milliseconds(500))
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "userpub", client: client, signer: signer))
        let resolved = try await pubkey.value
        #expect(resolved == "userpub")
    }

    // MARK: - disconnect / logout

    @Test("disconnect fails in-flight requests with notConnected")
    func disconnectFailsPending() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: 5)
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        _ = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        await remote.disconnect()

        await #expect(throws: RemoteSignerError.notConnected) { try await ping.value }
        #expect(await transport.isConnected == false)
    }

    @Test("logout sends a logout request then disconnects")
    func logoutSendsThenDisconnects() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: 5)
        try await connectHandshake(remote, transport: transport)

        async let logout: Void = remote.logout()
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)
        #expect(request.method == RemoteSignerMethod.logout.rawValue)
        // logout is best-effort; answer it so the send-side stream resolves promptly.
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        await logout
        #expect(await transport.isConnected == false)
    }

    // MARK: - Helpers

    /// Drives the connect handshake to completion so a test can then exercise commands.
    private func connectHandshake(_ remote: RemoteSigner, transport: FakeRemoteSignerTransport) async throws {
        async let connect: Void = remote.connect()
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        try await connect
    }
}
