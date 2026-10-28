import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrConnect

@Suite("RemoteSigner nostrconnect Flow Tests")
struct RemoteSignerNostrConnectFlowTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = KeyPair()
        self.signer = KeyPair()
    }

    private func makeInvitation() throws -> NostrConnectURI {
        try NostrConnectURI.invitation(clientKeyPair: client, relays: [RelayURL("wss://relay.example")!])
    }

    private func makeSigner(
        invitation: NostrConnectURI, transport: FakeRemoteSignerTransport, requestTimeout: Duration = .seconds(1)
    ) throws -> RemoteSigner {
        try RemoteSigner(
            invitation: invitation,
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: requestTimeout))
    }

    // MARK: - init validation

    @Test("init throws invalidURI when the keypair does not match the invitation public key")
    func initRejectsMismatchedKeyPair() async throws {
        let invitation = try makeInvitation()
        let otherKeyPair = KeyPair()

        #expect(throws: RemoteSignerError.invalidURI(reason: "client keypair does not match the invitation public key"))
        {
            _ = try RemoteSigner(
                invitation: invitation, clientKeyPair: otherKeyPair, transport: FakeRemoteSignerTransport())
        }
    }

    @Test("remoteSignerPublicKey is nil before the signer is discovered")
    func remoteSignerPublicKeyStartsNil() async throws {
        let invitation = try makeInvitation()
        let remote = try makeSigner(invitation: invitation, transport: FakeRemoteSignerTransport())
        #expect(await remote.remoteSignerPublicKey == nil)
    }

    // MARK: - happy path

    @Test("connect discovers the signer from a response echoing the invitation secret")
    func connectDiscoversSigner() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.connect() }

        // The client subscribes without pinning authors so it can hear the incoming connect ack.
        try await waitForSubscription(transport)
        let subscribed = await transport.subscriptions.values.first?.first
        #expect(subscribed?.authors == nil)
        #expect(subscribed?.publicKeyReferences == [client.publicKey])

        // The signer accepts by echoing the invitation secret as the response result.
        try await deliverAck(invitation, transport: transport)

        try await connection.value
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
        #expect(await remote.isConnectedForTesting == true)
        // The client never sends a request of its own in this flow.
        #expect(await transport.sentEvents.isEmpty)
    }

    @Test("connect re-pins the subscription to the discovered signer")
    func connectRepinsSubscription() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.connect() }
        try await waitForSubscription(transport)
        try await deliverAck(invitation, transport: transport)
        try await connection.value

        // After discovery the subscription is narrowed to the signer's public key for defense in depth.
        let repinned = await transport.subscriptions.values.first?.first
        #expect(repinned?.authors == [signer.publicKey])
    }

    @Test("connect after discovery returns at once without waiting for another reply")
    func repeatConnectIsNoOp() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.connect() }
        try await waitForSubscription(transport)
        try await deliverAck(invitation, transport: transport)
        try await connection.value

        try await remote.connect()
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
        #expect(await remote.isAwaitingConnectionForTesting == false)
    }

    /// The reply can be read as soon as the subscription exists, which may be before the discovery
    /// has registered its waiter; it must be held for the waiter rather than dropped.
    @Test("a reply that arrives while the session is still starting is not lost", .timeLimit(.minutes(1)))
    func earlyReplyIsBuffered() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))
        let ack = try RemoteSignerFixtures.response(
            requestID: "connect-ack", result: invitation.secret, client: client, signer: signer)
        await transport.deliverOnStart(ack)

        try await remote.connect()
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    // MARK: - secret validation

    @Test("connect ignores a response with the wrong secret and resolves on the correct one")
    func connectIgnoresWrongSecret() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.connect() }
        try await waitForSubscription(transport)

        // A spoofer answers with a result that is not the secret; the client must keep waiting.
        let spoofer = KeyPair()
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "spoof", result: "not-the-secret", client: client, signer: spoofer))

        // The waiter is still pending, so the connection task has not completed.
        #expect(await remote.remoteSignerPublicKey == nil)

        // Now the genuine signer echoes the correct secret and the connection resolves to it.
        try await deliverAck(invitation, transport: transport)

        try await connection.value
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    // MARK: - commands

    @Test("a command round-trips against the discovered signer after connection")
    func commandRoundTripsAfterConnection() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(2))

        let connection = Task { try await remote.connect() }
        try await waitForSubscription(transport)
        try await deliverAck(invitation, transport: transport)
        try await connection.value

        // A follow-up command is sent to and answered by the discovered signer.
        let publicKey = Task { try await remote.userPublicKey() }
        try await answerGetPublicKey(transport)
        #expect(try await publicKey.value == PublicKey.fixture("user"))
    }

    @Test("a command before discovery waits for the invitation reply, then succeeds", .timeLimit(.minutes(1)))
    func commandBeforeDiscoveryWaitsForReply() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let publicKey = Task { try await remote.userPublicKey() }
        try await waitForConnectWaiters(remote, count: 1)
        // The ack can only be heard once the session has subscribed and is waiting for it.
        try await waitForConnectionWaiter(remote)
        // Nothing can be addressed to the signer yet, so nothing has been sent.
        #expect(await transport.sentEvents.isEmpty)

        try await deliverAck(invitation, transport: transport)
        try await answerGetPublicKey(transport)

        #expect(try await publicKey.value == PublicKey.fixture("user"))
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    // MARK: - timeout

    @Test("connect times out when no valid response arrives")
    func connectTimesOut() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .milliseconds(200))

        await #expect(throws: RemoteSignerError.timedOut) {
            try await remote.connect()
        }
        #expect(await remote.remoteSignerPublicKey == nil)
    }

    // MARK: - session end

    /// No connect response can arrive once the relays' streams have ended, so the wait fails then
    /// rather than when its timeout elapses.
    /// The timeout is long enough to tell the two apart, yet bounds the run if this regresses.
    @Test("connect fails when the relays' event stream ends", .timeLimit(.minutes(1)))
    func connectFailsWhenEventStreamEnds() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let connection = Task { try await remote.connect() }
        try await waitForConnectionWaiter(remote)
        await transport.endEvents()

        await #expect(throws: RemoteSignerError.notConnected) { try await connection.value }
        #expect(await remote.isAwaitingConnectionForTesting == false)
    }

    @Test("connect fails when the session disconnects", .timeLimit(.minutes(1)))
    func connectFailsOnDisconnect() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let connection = Task { try await remote.connect() }
        try await waitForConnectionWaiter(remote)
        await remote.disconnect()

        await #expect(throws: RemoteSignerError.notConnected) { try await connection.value }
        #expect(await remote.isAwaitingConnectionForTesting == false)
    }

    // MARK: - cancellation

    @Test("cancelling the only connect fails it with cancelled and abandons the wait", .timeLimit(.minutes(1)))
    func connectCancellation() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let cancelled = Task { try await remote.connect() }
        try await waitForConnectionWaiter(remote)
        cancelled.cancel()

        await #expect(throws: RemoteSignerError.cancelled) { try await cancelled.value }
        // Nobody is left waiting, so the discovery itself is withdrawn.
        try await waitForNoConnectionWaiter(remote)

        // A later call starts a fresh wait, which resolves normally.
        let connection = Task { try await remote.connect() }
        try await waitForConnectionWaiter(remote)
        try await deliverAck(invitation, transport: transport)
        try await connection.value
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    // MARK: - concurrent calls

    @Test("concurrent connect calls both return after one valid reply", .timeLimit(.minutes(1)))
    func concurrentConnectsShareOneReply() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let first = Task { try await remote.connect() }
        let second = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)
        try await waitForConnectionWaiter(remote)

        try await deliverAck(invitation, transport: transport)

        try await first.value
        try await second.value
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    @Test("concurrent connect calls both time out together")
    func concurrentConnectsShareTimeout() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(1))

        let first = Task { try await remote.connect() }
        let second = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)

        await #expect(throws: RemoteSignerError.timedOut) { try await first.value }
        await #expect(throws: RemoteSignerError.timedOut) { try await second.value }
    }

    @Test("concurrent connect calls both fail when the session disconnects", .timeLimit(.minutes(1)))
    func concurrentConnectsShareSessionEnd() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let first = Task { try await remote.connect() }
        let second = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)
        try await waitForConnectionWaiter(remote)
        await remote.disconnect()

        await #expect(throws: RemoteSignerError.notConnected) { try await first.value }
        await #expect(throws: RemoteSignerError.notConnected) { try await second.value }
    }

    @Test("cancelling one of two connect calls leaves the other waiting and succeeding", .timeLimit(.minutes(1)))
    func cancellingOneConnectLeavesTheOther() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: .seconds(20))

        let cancelled = Task { try await remote.connect() }
        let survivor = Task { try await remote.connect() }
        try await waitForConnectWaiters(remote, count: 2)
        try await waitForConnectionWaiter(remote)

        cancelled.cancel()
        await #expect(throws: RemoteSignerError.cancelled) { try await cancelled.value }
        // The shared discovery keeps waiting for the survivor.
        #expect(await remote.connectWaiterCountForTesting == 1)
        #expect(await remote.isAwaitingConnectionForTesting == true)

        try await deliverAck(invitation, transport: transport)
        try await survivor.value
        #expect(await remote.remoteSignerPublicKey == signer.publicKey)
    }

    // MARK: - Helpers

    /// Polls until the session has registered its response subscription on the transport.
    private func waitForSubscription(_ transport: FakeRemoteSignerTransport) async throws {
        for _ in 0..<400 {
            if await !transport.subscriptions.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }

    /// Polls until the `nostrconnect://` discovery has registered its waiter on the session.
    private func waitForConnectionWaiter(_ remote: RemoteSigner) async throws {
        for _ in 0..<400 {
            if await remote.isAwaitingConnectionForTesting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }

    /// Polls until the `nostrconnect://` discovery has been withdrawn.
    private func waitForNoConnectionWaiter(_ remote: RemoteSigner) async throws {
        for _ in 0..<400 {
            if await !remote.isAwaitingConnectionForTesting { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }

    /// Polls until `count` ``RemoteSigner/connect()`` callers are waiting on the attempt in flight.
    private func waitForConnectWaiters(_ remote: RemoteSigner, count: Int) async throws {
        for _ in 0..<400 {
            if await remote.connectWaiterCountForTesting == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }

    /// Delivers the signer's acceptance of `invitation`: a response echoing its secret.
    private func deliverAck(_ invitation: NostrConnectURI, transport: FakeRemoteSignerTransport) async throws {
        let ack = try RemoteSignerFixtures.response(
            requestID: "connect-ack", result: invitation.secret, client: client, signer: signer)
        await transport.deliver(ack)
    }

    /// Waits for the first request the client sends, checks it is `get_public_key`, and answers it.
    private func answerGetPublicKey(_ transport: FakeRemoteSignerTransport) async throws {
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        #expect(request.method == RemoteSignerMethod.getPublicKey.rawValue)
        let reply = try RemoteSignerFixtures.response(
            requestID: request.id, result: PublicKey.fixture("user").hex, client: client, signer: signer)
        await transport.deliver(reply)
    }
}
