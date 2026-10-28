import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Session Tests")
struct RemoteSignerSessionTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = KeyPair()
        self.signer = KeyPair()
    }

    private func makeSigner(
        secret: String? = nil, transport: FakeRemoteSignerTransport, requestTimeout: Duration = .seconds(1)
    ) throws -> RemoteSigner {
        try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer, secret: secret),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: requestTimeout))
    }

    // MARK: - connect handshake

    @Test("the default configuration waits 30 seconds, and 5 minutes after a challenge")
    func configDefaults() {
        let config = RemoteSigner.Config()
        #expect(config.requestTimeout == .seconds(30))
        #expect(config.authChallengeTimeout == .seconds(300))
    }

    @Test("connect sends a kind-24133 connect request p-tagging the signer")
    func connectSendsRequest() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        async let connect: Void = remote.connect()

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let event = sent[0]
        #expect(event.kind == .nostrConnect)
        #expect(event.publicKey == client.publicKey)
        #expect(event.firstTagValue(named: "p") == signer.publicKey.hex)

        let request = try RemoteSignerFixtures.decryptRequest(event, client: client, signer: signer)
        #expect(request.method == RemoteSignerMethod.connect.rawValue)
        #expect(request.params == [signer.publicKey.hex])

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
        #expect(request.params == [signer.publicKey.hex, "s3cr3t"])

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

    @Test("concurrent connect calls send one connect request and both succeed", .timeLimit(.minutes(1)))
    func concurrentConnectsShareOneHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(20))

        let first = Task { try await remote.connect() }
        let second = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        let ack = try RemoteSignerFixtures.response(
            requestID: request.id, result: "ack", client: client, signer: signer)
        await transport.deliver(ack)

        try await first.value
        try await second.value
        #expect(await transport.sentEvents.count == 1)
        #expect(await remote.isConnectedForTesting == true)
    }

    @Test("concurrent connect calls both receive the signer's rejection", .timeLimit(.minutes(1)))
    func concurrentConnectsShareRejection() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(20))

        let first = Task { try await remote.connect() }
        let second = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        let reply = try RemoteSignerFixtures.response(
            requestID: request.id, result: "nope", client: client, signer: signer)
        await transport.deliver(reply)

        await #expect(throws: RemoteSignerError.connectionRejected(message: "nope")) { try await first.value }
        await #expect(throws: RemoteSignerError.connectionRejected(message: "nope")) { try await second.value }
        #expect(await transport.sentEvents.count == 1)
    }

    @Test("cancelling one of two connect calls leaves the handshake running for the other", .timeLimit(.minutes(1)))
    func cancellingOneConnectLeavesHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(20))

        let cancelled = Task { try await remote.connect() }
        let survivor = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)

        cancelled.cancel()
        await #expect(throws: RemoteSignerError.cancelled) { try await cancelled.value }

        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        let ack = try RemoteSignerFixtures.response(
            requestID: request.id, result: "ack", client: client, signer: signer)
        await transport.deliver(ack)

        try await survivor.value
        #expect(await transport.sentEvents.count == 1)
        #expect(await remote.isConnectedForTesting == true)
    }

    // MARK: - correlation by id

    @Test("concurrent requests resolve with their own responses, matched by id")
    func concurrentRequestsCorrelateByID() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        try await connectHandshake(remote, transport: transport)

        let publicKey = Task { try await remote.userPublicKey() }
        let pong = Task { try await remote.ping() }

        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 3)
        // The two commands are events 2 and 3 (event 1 was the connect request).
        let requests = try sent.dropFirst().map {
            try RemoteSignerFixtures.decryptRequest($0, client: client, signer: signer)
        }
        #expect(Set(requests.map(\.id)).count == 2)

        // Answer them out of order to prove correlation is by id, not arrival order.
        for request in requests.reversed() {
            let result = request.method == RemoteSignerMethod.ping.rawValue ? "pong" : PublicKey.fixture("user").hex
            try await transport.deliver(
                RemoteSignerFixtures.response(
                    requestID: request.id, result: result, client: client, signer: signer))
        }

        let resolved = try await publicKey.value
        #expect(resolved == PublicKey.fixture("user"))
        try await pong.value
    }

    @Test("a response with an unknown id is ignored")
    func unknownIDIgnored() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .milliseconds(300))
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

    @Test("a response from a non-signer public key is ignored")
    func nonSignerResponseIgnored() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .milliseconds(300))
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // A response encrypted by a different keypair, authored by an impostor, must be dropped.
        let impostor = KeyPair()
        let json = "{\"id\":\"\(request.id)\",\"result\":\"pong\"}"
        let encrypted = try NIP44Payload.encrypt(json, for: client.publicKey, using: impostor)
        let forged = Event(
            id: .fixture("forged"), publicKey: impostor.publicKey, createdAt: Timestamp(rawValue: 0),
            kind: .nostrConnect,
            tags: [.publicKey(client.publicKey)], content: encrypted.base64, signature: nil)
        await transport.deliver(forged)

        await #expect(throws: RemoteSignerError.timedOut) { try await ping.value }
    }

    // MARK: - timeout

    @Test("a request with no response times out")
    func requestTimesOut() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .milliseconds(200))
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
            config: .init(requestTimeout: .seconds(2), authChallengeTimeout: .seconds(60)))
        try await connectHandshake(remote, transport: transport)

        let challenges = await remote.authChallenges()

        let publicKey = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        // The request's timer started before it was sent, so it is due no later than this.
        let requestTimeoutDue = ContinuousClock.now + .seconds(2)
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

        // The request stays pending past requestTimeout; wait beyond it, then deliver the real
        // response and confirm it completes. requestTimeout only has to outlast the challenge's
        // delivery and authChallengeTimeout dwarfs the wait, so a slow runner cannot time it out.
        try await Task.sleep(until: requestTimeoutDue + .milliseconds(500), clock: .continuous)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: PublicKey.fixture("user").hex, client: client, signer: signer))
        let resolved = try await publicKey.value
        #expect(resolved == PublicKey.fixture("user"))
    }

    // MARK: - failures

    @Test("a relay that cannot be connected to surfaces as transportFailed")
    func connectFailureIsTyped() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        await transport.failNextConnect(with: .connectionFailed)

        do {
            try await remote.ping()
            Issue.record("ping succeeded without a relay")
        } catch {
            #expect(error == .transportFailed(.connectionFailed))
        }
        // The failed setup is not cached: the next call connects again.
        try await connectHandshake(remote, transport: transport)
        #expect(await transport.connectCount == 2)
    }

    @Test("a request the relay cannot take surfaces as transportFailed")
    func sendFailureIsTyped() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        try await connectHandshake(remote, transport: transport)
        await transport.failNextSend(with: .notConnected)

        await #expect(throws: RemoteSignerError.transportFailed(.notConnected)) {
            try await remote.ping()
        }
    }

    @Test("cancelling a request waiting for its response fails it with cancelled at once")
    func cancelledRequestIsTyped() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(60))
        try await connectHandshake(remote, transport: transport)

        let ping = Task { try await remote.ping() }
        _ = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        ping.cancel()

        await #expect(throws: RemoteSignerError.cancelled) { try await ping.value }
    }

    // MARK: - disconnect / logout

    @Test("disconnect fails in-flight requests with notConnected")
    func disconnectFailsPending() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(5))
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
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(5))
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

    // MARK: - Auth-challenge stream lifetime

    /// The merged event stream ends when every relay's has — automatic reconnection gave up, or the
    /// connections went away. No challenge can arrive after that, so a stream left open would keep
    /// its consumer's `for await` loop suspended forever, with nothing saying why.
    @Test("auth-challenge streams finish when the relays' event stream ends", .timeLimit(.minutes(1)))
    func authChallengeStreamsFinishWhenEventStreamEnds() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)
        try await connectHandshake(remote, transport: transport)
        let first = await remote.authChallenges()
        let second = await remote.authChallenges()
        let drained = Task {
            var received = 0
            for await _ in first { received += 1 }
            return received
        }

        await transport.endEvents()

        #expect(await drained.value == 0)
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test(
        "an auth-challenge stream opened after the event stream ended gets the next request's challenges",
        .timeLimit(.minutes(1)))
    func authChallengesAfterEventStreamEnded() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(5))
        try await connectHandshake(remote, transport: transport)
        let ended = await remote.authChallenges()
        await transport.endEvents()
        for await _ in ended {}

        var iterator = await remote.authChallenges().makeAsyncIterator()
        // The next request reconnects rather than sending into the ended stream.
        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        #expect(await transport.connectCount == 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "auth_url", error: "https://auth.example",
                client: client, signer: signer))
        #expect(await iterator.next()?.requestID == request.id)

        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: "pong", client: client, signer: signer))
        try await ping.value
    }

    @Test("disconnect finishes auth-challenge streams, and one opened afterwards stays live", .timeLimit(.minutes(1)))
    func disconnectFinishesAuthChallengeStreams() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport, requestTimeout: .seconds(5))
        try await connectHandshake(remote, transport: transport)
        let old = await remote.authChallenges()
        await remote.disconnect()
        for await _ in old {}

        var iterator = await remote.authChallenges().makeAsyncIterator()
        // Give the disconnected session's reader every chance to wake and finish the new stream.
        try await Task.sleep(for: .milliseconds(200))

        let ping = Task { try await remote.ping() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "auth_url", error: "https://auth.example",
                client: client, signer: signer))
        #expect(await iterator.next()?.requestID == request.id)

        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: "pong", client: client, signer: signer))
        try await ping.value
    }

    // MARK: - Helpers

    /// Polls until `count` ``RemoteSigner/connect()`` callers are waiting on the attempt in flight.
    private func waitForConnectWaiters(_ remote: RemoteSigner, count: Int) async throws {
        for _ in 0..<400 {
            if await remote.connectWaiterCountForTesting == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }

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
