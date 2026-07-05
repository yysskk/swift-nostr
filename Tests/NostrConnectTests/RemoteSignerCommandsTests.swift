import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Commands Tests")
struct RemoteSignerCommandsTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = try KeyPair()
        self.signer = try KeyPair()
    }

    /// A connected ``RemoteSigner`` with its fake transport, ready for command tests.
    private func connected(requestTimeout: TimeInterval = 1) async throws -> (RemoteSigner, FakeRemoteSignerTransport) {
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: requestTimeout))
        async let connect: Void = remote.connect()
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 1)
        let request = try RemoteSignerFixtures.decryptRequest(sent[0], client: client, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ack", client: client, signer: signer))
        try await connect
        return (remote, transport)
    }

    /// Waits for the next request after the connect handshake and returns it (event index 1).
    private func nextRequest(_ transport: FakeRemoteSignerTransport) async throws -> RemoteSignerRequest {
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 2)
        return try RemoteSignerFixtures.decryptRequest(sent[1], client: client, signer: signer)
    }

    // MARK: - get_public_key

    @Test("userPublicKey round-trips and caches the result")
    func userPublicKeyRoundTripsAndCaches() async throws {
        let (remote, transport) = try await connected()

        let first = Task { try await remote.userPublicKey() }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.getPublicKey.rawValue)
        #expect(request.params.isEmpty)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "userpubhex", client: client, signer: signer))
        let resolved = try await first.value
        #expect(resolved == "userpubhex")

        // The second call is served from cache — no new request event is sent.
        let cached = try await remote.userPublicKey()
        #expect(cached == "userpubhex")
        #expect(await transport.sentEvents.count == 2)
    }

    // MARK: - sign_event

    @Test("sign returns a verifiable event matching the request")
    func signHappyPath() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            pubkey: signer.publicKeyHex, createdAt: 1000, kind: .textNote, rawTags: [["t", "nostr"]],
            content: "hello from the bunker")

        async let signed = remote.sign(unsigned)
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.signEvent.rawValue)

        // The signer reconstructs the unsigned event, signs it, and returns the JSON event.
        let toSign = try RemoteSignerFixtures.unsignedEvent(from: request, author: signer.publicKeyHex)
        let json = try RemoteSignerFixtures.signedEventJSON(toSign, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: json, client: client, signer: signer))

        let event = try await signed
        #expect(try event.verify() == true)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello from the bunker")
        #expect(event.tags == [["t", "nostr"]])
        #expect(event.createdAt == 1000)
        #expect(event.pubkey == signer.publicKeyHex)
    }

    @Test("sign rejects a tampered event whose content was altered after signing")
    func signRejectsTampered() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            pubkey: signer.publicKeyHex, createdAt: 1000, kind: .textNote, content: "original")

        let signed = Task { try await remote.sign(unsigned) }
        let request = try await nextRequest(transport)

        // Sign the requested event, then tamper with the returned content so id/sig no longer match.
        let toSign = try RemoteSignerFixtures.unsignedEvent(from: request, author: signer.publicKeyHex)
        let realJSON = try RemoteSignerFixtures.signedEventJSON(toSign, signer: signer)
        let tamperedJSON = realJSON.replacingOccurrences(of: "original", with: "tampered")
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: tamperedJSON, client: client, signer: signer))

        await #expect(throws: RemoteSignerError.responseValidationFailed) { try await signed.value }
    }

    @Test("sign rejects a validly-signed event whose content differs from the request")
    func signRejectsMismatchedContent() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            pubkey: signer.publicKeyHex, createdAt: 1000, kind: .textNote, content: "requested")

        let signed = Task { try await remote.sign(unsigned) }
        let request = try await nextRequest(transport)

        // The signer signs a *different* event (valid signature, wrong content) — must be rejected.
        let other = UnsignedEvent(
            pubkey: signer.publicKeyHex, createdAt: 1000, kind: .textNote, content: "something else")
        let json = try RemoteSignerFixtures.signedEventJSON(other, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: json, client: client, signer: signer))

        await #expect(throws: RemoteSignerError.responseValidationFailed) { try await signed.value }
    }

    // MARK: - ping

    @Test("ping succeeds on pong")
    func pingSucceeds() async throws {
        let (remote, transport) = try await connected()
        async let pong: Void = remote.ping()
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.ping.rawValue)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "pong", client: client, signer: signer))
        try await pong
    }

    @Test("ping fails validation on a non-pong reply")
    func pingRejectsNonPong() async throws {
        let (remote, transport) = try await connected()
        let pong = Task { try await remote.ping() }
        let request = try await nextRequest(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "nope", client: client, signer: signer))
        await #expect(throws: RemoteSignerError.responseValidationFailed) { try await pong.value }
    }

    // MARK: - nip44 / nip04

    @Test("nip44Encrypt sends third-party pubkey then plaintext and returns the ciphertext")
    func nip44EncryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKeyHex

        let ciphertext = Task { try await remote.nip44Encrypt("secret message", to: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip44Encrypt.rawValue)
        #expect(request.params == [third, "secret message"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "cipher==", client: client, signer: signer))
        let resolved = try await ciphertext.value
        #expect(resolved == "cipher==")
    }

    @Test("nip44Decrypt sends third-party pubkey then ciphertext and returns the plaintext")
    func nip44DecryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKeyHex

        let plaintext = Task { try await remote.nip44Decrypt("cipher==", from: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip44Decrypt.rawValue)
        #expect(request.params == [third, "cipher=="])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "plain text", client: client, signer: signer))
        let resolved = try await plaintext.value
        #expect(resolved == "plain text")
    }

    @Test("nip04Encrypt sends third-party pubkey then plaintext")
    func nip04EncryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKeyHex

        let ciphertext = Task { try await remote.nip04Encrypt("hi", to: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip04Encrypt.rawValue)
        #expect(request.params == [third, "hi"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ct?iv=iv", client: client, signer: signer))
        let resolved = try await ciphertext.value
        #expect(resolved == "ct?iv=iv")
    }

    // MARK: - switch_relays

    @Test("switchRelays parses a JSON array of relay URLs")
    func switchRelaysReturnsURLs() async throws {
        let (remote, transport) = try await connected()

        let relays = Task { try await remote.switchRelays() }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.switchRelays.rawValue)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id,
                result: #"["wss://a.example","wss://b.example"]"#,
                client: client, signer: signer))

        let urls = try await relays.value
        #expect(urls == [URL(string: "wss://a.example")!, URL(string: "wss://b.example")!])
    }

    @Test("switchRelays returns nil when the signer keeps its relays")
    func switchRelaysReturnsNil() async throws {
        let (remote, transport) = try await connected()

        let relays = Task { try await remote.switchRelays() }
        let request = try await nextRequest(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "null", client: client, signer: signer))
        let resolved = try await relays.value
        #expect(resolved == nil)
    }
}
