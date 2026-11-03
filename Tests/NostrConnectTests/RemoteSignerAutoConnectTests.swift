import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Automatic Connect Tests")
struct RemoteSignerAutoConnectTests {
    private let client = KeyPair()
    private let signer = KeyPair()

    private func makeSigner(
        secret: String? = nil,
        permissions: [RemoteSignerPermission] = [],
        connectsAutomatically: Bool = true,
        transport: FakeRemoteSignerTransport
    ) throws -> RemoteSigner {
        try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer, secret: secret),
            clientKeyPair: client,
            permissions: permissions,
            transport: transport,
            config: .init(requestTimeout: .seconds(5), connectsAutomatically: connectsAutomatically))
    }

    /// Waits for the request at `index` and answers it with `result`, returning the request.
    @discardableResult
    private func answerRequest(
        at index: Int, with result: String, transport: FakeRemoteSignerTransport
    ) async throws -> RemoteSignerRequest {
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: index + 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[index], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: result, client: client, signer: signer))
        return request
    }

    @Test("the first command sends the handshake, with the secret and permissions, and then itself")
    func firstCommandSendsHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cr3t", permissions: [.nip44Encrypt], transport: transport)

        async let ping: Void = remote.ping()

        let handshake = try await answerRequest(at: 0, with: "ack", transport: transport)
        #expect(handshake.method == RemoteSignerMethod.connect.rawValue)
        #expect(handshake.params == [signer.publicKey.hex, "s3cr3t", "nip44_encrypt"])

        let command = try await answerRequest(at: 1, with: "pong", transport: transport)
        #expect(command.method == RemoteSignerMethod.ping.rawValue)

        try await ping
        #expect(await remote.isConnectedForTesting)
    }

    @Test("later commands do not repeat the handshake")
    func laterCommandsSkipHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        async let first: Void = remote.ping()
        try await answerRequest(at: 0, with: "ack", transport: transport)
        try await answerRequest(at: 1, with: "pong", transport: transport)
        try await first

        async let second: Void = remote.ping()
        let command = try await answerRequest(at: 2, with: "pong", transport: transport)
        try await second

        #expect(command.method == RemoteSignerMethod.ping.rawValue)
        #expect(await transport.sentEvents.count == 3)
    }

    @Test("a rejected handshake fails the command, which is not sent")
    func rejectedHandshakeFailsCommand() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cr3t", transport: transport)

        let ping = Task { try await remote.ping() }
        try await answerRequest(at: 0, with: "not-the-secret", transport: transport)

        await #expect(throws: RemoteSignerError.connectionRejected(message: "not-the-secret")) {
            try await ping.value
        }
        #expect(await transport.sentEvents.count == 1)
    }

    @Test("concurrent commands share one handshake", .timeLimit(.minutes(1)))
    func concurrentCommandsShareHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        let first = Task { try await remote.ping() }
        let second = Task { try await remote.ping() }

        try await answerRequest(at: 0, with: "ack", transport: transport)
        try await answerRequest(at: 1, with: "pong", transport: transport)
        try await answerRequest(at: 2, with: "pong", transport: transport)
        try await first.value
        try await second.value

        let methods = try await transport.sentEvents.map {
            try RemoteSignerFixtures.decryptRequest($0, client: client, signer: signer).method
        }
        #expect(methods.filter { $0 == RemoteSignerMethod.connect.rawValue }.count == 1)
        #expect(methods.count == 3)
    }

    @Test("a command after disconnect runs the handshake again")
    func commandAfterDisconnectReconnects() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        async let first: Void = remote.ping()
        try await answerRequest(at: 0, with: "ack", transport: transport)
        try await answerRequest(at: 1, with: "pong", transport: transport)
        try await first
        await remote.disconnect()

        async let second: Void = remote.ping()
        let handshake = try await answerRequest(at: 2, with: "ack", transport: transport)
        try await answerRequest(at: 3, with: "pong", transport: transport)
        try await second

        #expect(handshake.method == RemoteSignerMethod.connect.rawValue)
    }

    @Test("with connectsAutomatically off, a command goes out without the handshake")
    func optOutSkipsHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "spent", connectsAutomatically: false, transport: transport)

        async let ping: Void = remote.ping()
        let command = try await answerRequest(at: 0, with: "pong", transport: transport)
        try await ping

        #expect(command.method == RemoteSignerMethod.ping.rawValue)
        #expect(await remote.isConnectedForTesting == false)
    }

    @Test("logout does not run the handshake")
    func logoutSkipsHandshake() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cr3t", transport: transport)

        let ping = Task { try await remote.ping() }
        try await answerRequest(at: 0, with: "rejected", transport: transport)
        _ = await ping.result

        async let logout: Void = remote.logout()
        let request = try await answerRequest(at: 1, with: "ack", transport: transport)
        await logout

        #expect(request.method == RemoteSignerMethod.logout.rawValue)
    }

    @Test("a nostrconnect session's command after disconnect sends no connect request", .timeLimit(.minutes(1)))
    func invitationSessionAfterDisconnect() async throws {
        let invitation = try NostrConnectURI.invitation(
            clientKeyPair: client, relays: [RelayURL("wss://relay.example")!])
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            invitation: invitation, clientKeyPair: client, transport: transport,
            config: .init(requestTimeout: .seconds(5)))

        let connect = Task { try await remote.connect() }
        while await remote.isAwaitingConnectionForTesting == false {
            await Task.yield()
        }
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: "reply", result: invitation.secret, client: client, signer: signer))
        try await connect.value
        await remote.disconnect()

        async let ping: Void = remote.ping()
        let command = try await answerRequest(at: 0, with: "pong", transport: transport)
        try await ping

        #expect(command.method == RemoteSignerMethod.ping.rawValue)
        #expect(await remote.isConnectedForTesting)
    }
}
