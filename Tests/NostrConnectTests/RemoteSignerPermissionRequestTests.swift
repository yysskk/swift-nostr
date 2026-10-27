import Foundation
import NostrCore
import Testing

@testable import NostrConnect

/// NIP-46's `connect` takes the permissions a client wants granted, so the signer can authorize them
/// once instead of interrupting the user for every operation. This client never sent them, so a
/// `bunker://` session could not pre-authorize anything: each command drew its own `auth_url`
/// round-trip.
@Suite("RemoteSigner Permission Request Tests")
struct RemoteSignerPermissionRequestTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = KeyPair()
        self.signer = KeyPair()
    }

    private func makeSigner(
        secret: String? = nil,
        permissions: [RemoteSignerPermission] = [],
        transport: FakeRemoteSignerTransport
    ) throws -> RemoteSigner {
        try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer, secret: secret),
            clientKeyPair: client,
            requesting: permissions,
            transport: transport,
            config: .init(requestTimeout: .seconds(1)))
    }

    /// The params are positional, so the permissions sit third — after the secret slot, which has to
    /// be present even when the token carries no secret.
    @Test("connect sends the requested permissions")
    func connectSendsPermissions() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(
            permissions: [.signEvent(kind: .textNote), .nip44Decrypt],
            transport: transport)

        let connect = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)

        #expect(request.params == [signer.publicKey.hex, "", "sign_event:1,nip44_decrypt"])
        connect.cancel()
    }

    @Test("connect sends the secret alongside the permissions")
    func connectSendsSecretAndPermissions() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(
            secret: "s3cret", permissions: [.getPublicKey], transport: transport)

        let connect = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)

        #expect(request.params == [signer.publicKey.hex, "s3cret", "get_public_key"])
        connect.cancel()
    }

    /// Requesting nothing keeps the wire shape a signer already accepts, so this stays compatible
    /// with the sessions that worked before.
    @Test("connect omits the permission slot when none are requested")
    func connectOmitsEmptyPermissions() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(transport: transport)

        let connect = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)

        #expect(request.params == [signer.publicKey.hex])
        connect.cancel()
    }

    @Test("a permission's wire token matches NIP-46")
    func permissionTokens() {
        #expect(RemoteSignerPermission.signEvent(kind: .textNote).rawValue == "sign_event:1")
        #expect(RemoteSignerPermission.signEvent().rawValue == "sign_event")
        #expect(RemoteSignerPermission.nip44Encrypt.rawValue == "nip44_encrypt")
        #expect(RemoteSignerPermission.getPublicKey.rawValue == "get_public_key")
    }

    // MARK: - Constant-time secret comparison

    @Test("secret comparison is exact")
    func constantTimeComparisonIsExact() {
        #expect(RemoteSigner.constantTimeEquals("secret", "secret"))
        #expect(!RemoteSigner.constantTimeEquals("secret", "secrez"))
        #expect(!RemoteSigner.constantTimeEquals("secret", "secre"))
        #expect(!RemoteSigner.constantTimeEquals("secret", "secrett"))
        #expect(!RemoteSigner.constantTimeEquals("", "x"))
        #expect(RemoteSigner.constantTimeEquals("", ""))
    }

    /// A signer that echoes the secret rather than "ack" is still accepted — the comparison changed,
    /// not what counts as a valid acknowledgement.
    @Test("a secret echoed back still completes the handshake")
    func echoedSecretIsAccepted() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cret", transport: transport)

        let connect = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)

        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: request.id, result: "s3cret", client: client, signer: signer))

        try await connect.value
    }

    @Test("a wrong secret is rejected")
    func wrongSecretIsRejected() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try makeSigner(secret: "s3cret", transport: transport)

        let connect = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)

        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: request.id, result: "wrong", client: client, signer: signer))

        await #expect(throws: RemoteSignerError.connectionRejected(message: "wrong")) {
            try await connect.value
        }
    }

    // MARK: - Bounded auth challenges

    /// Every `auth_url` replaced the request's timeout, so a signer that kept sending them held the
    /// caller suspended with no end. The first challenge now fixes a deadline and later ones may
    /// only postpone up to it, so the wait stays the window the caller configured.
    @Test("repeated auth challenges cannot extend a request indefinitely", .timeLimit(.minutes(1)))
    func repeatedAuthChallengesAreBounded() async throws {
        let transport = FakeRemoteSignerTransport()
        // requestTimeout outlasts the whole challenge run, so only the challenge window can end the
        // request before the challenger gives up.
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: .seconds(30), authChallengeTimeout: .milliseconds(500)))

        let connectTask = Task { try await remote.connect() }
        let connectSent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let connectRequest = try RemoteSignerFixtures.decryptRequest(
            connectSent[0], client: client, signer: signer)
        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: connectRequest.id, result: "ack", client: client, signer: signer))
        try await connectTask.value

        let publicKey = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // A signer that keeps challenging and never answers, for twenty times one challenge window.
        // It reports whether it was stopped while still challenging rather than running out.
        let challenger = Task {
            for _ in 0..<50 {
                await transport.deliver(
                    try RemoteSignerFixtures.response(
                        requestID: request.id, result: "auth_url", error: "https://auth.example",
                        client: client, signer: signer))
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return true
                }
            }
            return false
        }

        await #expect(throws: RemoteSignerError.timedOut) { _ = try await publicKey.value }
        challenger.cancel()

        // Bounded, the request fails about one 0.5 s window after the first challenge, with the
        // challenger still going. Unbounded, each challenge pushed the deadline out again and the
        // request outlived the whole ~10 s run.
        #expect(try await challenger.value)

        // The deadline is cleared when the request ends, however it ends. Tracked only until a
        // later non-channel response arrived, an abandoned prompt like this one left it behind for
        // the signer's lifetime.
        #expect(await remote.authChallengeDeadlineCount == 0)
    }

    /// A challenge whose id matches nothing in flight has no request to clean up after it, so
    /// recording a deadline for it would leave an entry nothing ever removes.
    @Test("a challenge for an unknown request records no deadline")
    func strayChallengeRecordsNoDeadline() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: .milliseconds(300), authChallengeTimeout: .seconds(5)))

        let connectTask = Task { try await remote.connect() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        try await connectTask.value

        // An auth_url naming a request that was never made.
        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: "no-such-request", result: "auth_url", error: "https://auth.example",
                client: client, signer: signer))
        try await Task.sleep(for: .milliseconds(100))

        #expect(await remote.authChallengeDeadlineCount == 0)
    }
}
