import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner nostrconnect Flow Tests")
struct RemoteSignerNostrConnectFlowTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = try KeyPair()
        self.signer = try KeyPair()
    }

    private func makeInvitation() throws -> NostrConnectURI {
        try NostrConnectURI.invitation(clientKeyPair: client, relays: [URL(string: "wss://relay.example")!])
    }

    private func makeSigner(
        invitation: NostrConnectURI, transport: FakeRemoteSignerTransport, requestTimeout: TimeInterval = 1
    ) throws -> RemoteSigner {
        try RemoteSigner(
            invitation: invitation,
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: requestTimeout))
    }

    // MARK: - init validation

    @Test("init throws invalidURI when the keypair does not match the invitation pubkey")
    func initRejectsMismatchedKeyPair() async throws {
        let invitation = try makeInvitation()
        let otherKeyPair = try KeyPair()

        #expect(throws: RemoteSignerError.invalidURI(reason: "client keypair does not match the invitation pubkey")) {
            _ = try RemoteSigner(
                invitation: invitation, clientKeyPair: otherKeyPair, transport: FakeRemoteSignerTransport())
        }
    }

    @Test("remoteSignerPubkey is nil before the signer is discovered")
    func remoteSignerPubkeyStartsNil() async throws {
        let invitation = try makeInvitation()
        let remote = try makeSigner(invitation: invitation, transport: FakeRemoteSignerTransport())
        #expect(await remote.remoteSignerPubkey == nil)
    }

    // MARK: - happy path

    @Test("awaitConnection discovers the signer from a response echoing the invitation secret")
    func awaitConnectionDiscoversSigner() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.awaitConnection() }

        // The client subscribes without pinning authors so it can hear the incoming connect ack.
        try await waitForSubscription(transport)
        let subscribed = await transport.subscriptions.values.first?.first
        #expect(subscribed?.authors == nil)
        #expect(subscribed?.pubkeyReferences == [client.publicKeyHex])

        // The signer accepts by echoing the invitation secret as the response result.
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "connect-ack", result: invitation.secret, client: client, signer: signer))

        let discovered = try await connection.value
        #expect(discovered == signer.publicKeyHex)
        #expect(await remote.remoteSignerPubkey == signer.publicKeyHex)
        #expect(await remote.isConnectedForTesting == true)
    }

    @Test("awaitConnection re-pins the subscription to the discovered signer")
    func awaitConnectionRepinsSubscription() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.awaitConnection() }
        try await waitForSubscription(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "connect-ack", result: invitation.secret, client: client, signer: signer))
        _ = try await connection.value

        // After discovery the subscription is narrowed to the signer's pubkey for defense in depth.
        let repinned = await transport.subscriptions.values.first?.first
        #expect(repinned?.authors == [signer.publicKeyHex])
    }

    // MARK: - secret validation

    @Test("awaitConnection ignores a response with the wrong secret and resolves on the correct one")
    func awaitConnectionIgnoresWrongSecret() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport)

        let connection = Task { try await remote.awaitConnection() }
        try await waitForSubscription(transport)

        // A spoofer answers with a result that is not the secret; the client must keep waiting.
        let spoofer = try KeyPair()
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "spoof", result: "not-the-secret", client: client, signer: spoofer))

        // The waiter is still pending, so the connection task has not completed.
        #expect(await remote.remoteSignerPubkey == nil)

        // Now the genuine signer echoes the correct secret and the connection resolves to it.
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "connect-ack", result: invitation.secret, client: client, signer: signer))

        let discovered = try await connection.value
        #expect(discovered == signer.publicKeyHex)
    }

    // MARK: - post-connection command

    @Test("a command round-trips against the discovered signer after connection")
    func commandRoundTripsAfterConnection() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: 2)

        let connection = Task { try await remote.awaitConnection() }
        try await waitForSubscription(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "connect-ack", result: invitation.secret, client: client, signer: signer))
        _ = try await connection.value

        // A follow-up command is sent to and answered by the discovered signer.
        let pubkey = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        #expect(request.method == RemoteSignerMethod.getPublicKey.rawValue)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "userpub", client: client, signer: signer))

        #expect(try await pubkey.value == "userpub")
    }

    // MARK: - timeout

    @Test("awaitConnection times out when no valid response arrives")
    func awaitConnectionTimesOut() async throws {
        let invitation = try makeInvitation()
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(invitation: invitation, transport: transport, requestTimeout: 0.2)

        await #expect(throws: RemoteSignerError.timedOut) {
            try await remote.awaitConnection()
        }
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
}
