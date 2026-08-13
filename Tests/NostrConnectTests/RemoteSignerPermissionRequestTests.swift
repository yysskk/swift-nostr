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
        self.client = try KeyPair()
        self.signer = try KeyPair()
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
            config: .init(requestTimeout: 1))
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

        #expect(request.params == [signer.publicKeyHex, "", "sign_event:1,nip44_decrypt"])
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

        #expect(request.params == [signer.publicKeyHex, "s3cret", "get_public_key"])
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

        #expect(request.params == [signer.publicKeyHex])
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
    @Test("repeated auth challenges cannot extend a request indefinitely")
    func repeatedAuthChallengesAreBounded() async throws {
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: 0.2, authChallengeTimeout: 0.5))

        let connectTask = Task { try await remote.connect() }
        let connectSent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let connectRequest = try RemoteSignerFixtures.decryptRequest(
            connectSent[0], client: client, signer: signer)
        await transport.deliver(
            try RemoteSignerFixtures.response(
                requestID: connectRequest.id, result: "ack", client: client, signer: signer))
        try await connectTask.value

        let pubkey = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        let request = try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)

        // A signer that keeps challenging and never answers, for well past one challenge window.
        let clock = ContinuousClock()
        let start = clock.now
        let challenger = Task {
            for _ in 0..<10 {
                await transport.deliver(
                    try RemoteSignerFixtures.response(
                        requestID: request.id, result: "auth_url", error: "https://auth.example",
                        client: client, signer: signer))
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        await #expect(throws: RemoteSignerError.timedOut) { _ = try await pubkey.value }
        let elapsed = clock.now - start
        challenger.cancel()

        // Bounded, the request fails about one 0.5 s window in. Unbounded, each of the ten
        // challenges pushed the deadline out again and it would survive the full ~2 s of them and
        // then some, so the bound sits between the two.
        #expect(elapsed < .seconds(1.5))
    }
}
