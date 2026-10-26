import Foundation
import NostrCore
import NostrTestSupport
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
    private func connected(requestTimeout: Duration = .seconds(1)) async throws -> (
        RemoteSigner, FakeRemoteSignerTransport
    ) {
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
                requestID: request.id, result: PublicKey.fixture("user").hex, client: client, signer: signer))
        let resolved = try await first.value
        #expect(resolved == PublicKey.fixture("user"))

        // The second call is served from cache — no new request event is sent.
        let cached = try await remote.userPublicKey()
        #expect(cached == PublicKey.fixture("user"))
        #expect(await transport.sentEvents.count == 2)
    }

    // MARK: - sign_event

    @Test("sign returns a verifiable event matching the request")
    func signHappyPath() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote,
            rawTags: [["t", "nostr"]],
            content: "hello from the bunker")

        async let signed = remote.sign(unsigned)
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.signEvent.rawValue)

        // The signer reconstructs the unsigned event, signs it, and returns the JSON event.
        let toSign = try RemoteSignerFixtures.unsignedEvent(from: request, author: signer.publicKey)
        let json = try RemoteSignerFixtures.signedEventJSON(toSign, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: json, client: client, signer: signer))

        let event = try await signed
        #expect(try event.verify() == true)
        #expect(event.kind == .textNote)
        #expect(event.content == "hello from the bunker")
        #expect(event.tags == [["t", "nostr"]])
        #expect(event.createdAt.rawValue == 1000)
        #expect(event.publicKey == signer.publicKey)
    }

    @Test("sign rejects a tampered event whose content was altered after signing")
    func signRejectsTampered() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote, content: "original")

        let signed = Task { try await remote.sign(unsigned) }
        let request = try await nextRequest(transport)

        // Sign the requested event, then tamper with the returned content so id/sig no longer match.
        let toSign = try RemoteSignerFixtures.unsignedEvent(from: request, author: signer.publicKey)
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
            publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote, content: "requested")

        let signed = Task { try await remote.sign(unsigned) }
        let request = try await nextRequest(transport)

        // The signer signs a *different* event (valid signature, wrong content) — must be rejected.
        let other = UnsignedEvent(
            publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote,
            content: "something else")
        let json = try RemoteSignerFixtures.signedEventJSON(other, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: json, client: client, signer: signer))

        await #expect(throws: RemoteSignerError.responseValidationFailed) { try await signed.value }
    }

    @Test("sign rejects an event signed by a different key than requested")
    func signRejectsWrongPublicKey() async throws {
        let (remote, transport) = try await connected()
        let unsigned = UnsignedEvent(
            publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote, content: "requested")

        let signed = Task { try await remote.sign(unsigned) }
        let request = try await nextRequest(transport)

        // A hostile signer returns a self-consistent event with matching kind/content/tags/created_at
        // but authored under a *different* key. verify() alone would accept it, so the public key check
        // must reject it.
        let attacker = try KeyPair()
        let forged = UnsignedEvent(
            publicKey: attacker.publicKey, createdAt: Timestamp(rawValue: 1000), kind: .textNote, content: "requested")
        let json = try RemoteSignerFixtures.signedEventJSON(forged, signer: attacker)
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

    /// The reply is whatever the signer chose to send, so anything but a canonical key is rejected
    /// rather than handed back as the identity events would be authored under — and not cached.
    @Test(
        "userPublicKey rejects a reply that is not a canonical hex public key",
        arguments: ["userpubhex", String(repeating: "A", count: 64), String(repeating: "0", count: 63)])
    func userPublicKeyRejectsMalformedReply(reply: String) async throws {
        let (remote, transport) = try await connected()

        let first = Task { try await remote.userPublicKey() }
        let request = try await nextRequest(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: reply, client: client, signer: signer))
        await #expect(throws: RemoteSignerError.responseValidationFailed) { try await first.value }

        // Nothing was cached: the next call asks the signer again.
        let second = Task { try await remote.userPublicKey() }
        let sent = try await RemoteSignerFixtures.waitForSentEvents(transport, count: 3)
        let retry = try RemoteSignerFixtures.decryptRequest(sent[2], client: client, signer: signer)
        #expect(retry.method == RemoteSignerMethod.getPublicKey.rawValue)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: retry.id, result: PublicKey.fixture("user").hex, client: client, signer: signer))
        #expect(try await second.value == PublicKey.fixture("user"))
    }

    // MARK: - nip44 / nip04

    @Test("nip44Encrypt sends third-party public key then plaintext and returns the ciphertext")
    func nip44EncryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKey

        let ciphertext = Task { try await remote.nip44Encrypt("secret message", to: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip44Encrypt.rawValue)
        #expect(request.params == [third.hex, "secret message"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "cipher==", client: client, signer: signer))
        let resolved = try await ciphertext.value
        #expect(resolved == "cipher==")
    }

    @Test("nip44Decrypt sends third-party public key then ciphertext and returns the plaintext")
    func nip44DecryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKey

        let plaintext = Task { try await remote.nip44Decrypt("cipher==", from: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip44Decrypt.rawValue)
        #expect(request.params == [third.hex, "cipher=="])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "plain text", client: client, signer: signer))
        let resolved = try await plaintext.value
        #expect(resolved == "plain text")
    }

    @Test("nip04Encrypt sends third-party public key then plaintext")
    func nip04EncryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKey

        let ciphertext = Task { try await remote.nip04Encrypt("hi", to: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip04Encrypt.rawValue)
        #expect(request.params == [third.hex, "hi"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "ct?iv=iv", client: client, signer: signer))
        let resolved = try await ciphertext.value
        #expect(resolved == "ct?iv=iv")
    }

    @Test("nip04Decrypt sends third-party public key then ciphertext and returns the plaintext")
    func nip04DecryptRoundTrip() async throws {
        let (remote, transport) = try await connected()
        let third = try KeyPair().publicKey

        let plaintext = Task { try await remote.nip04Decrypt("ct?iv=iv", from: third) }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.nip04Decrypt.rawValue)
        #expect(request.params == [third.hex, "ct?iv=iv"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "hi", client: client, signer: signer))
        let resolved = try await plaintext.value
        #expect(resolved == "hi")
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
        #expect(urls == [RelayURL("wss://a.example")!, RelayURL("wss://b.example")!])
    }

    @Test(
        "switchRelays rejects an entry that is not a relay URL instead of dropping it",
        arguments: [#"["wss://a.example","https://b.example"]"#, #"["wss://a.example","not a relay"]"#])
    func switchRelaysRejectsMalformedEntry(result: String) async throws {
        let (remote, transport) = try await connected()

        let relays = Task { try await remote.switchRelays() }
        let request = try await nextRequest(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: result, client: client, signer: signer))

        await #expect(throws: RemoteSignerError.responseDecodingFailed) {
            _ = try await relays.value
        }
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

    // MARK: - send

    @Test("send carries a custom method and its params and returns the result")
    func sendCustomMethod() async throws {
        let (remote, transport) = try await connected()
        let method = RemoteSignerMethod(rawValue: "get_session_info")

        let result = Task { try await remote.send(method, params: ["first", "second"]) }
        let request = try await nextRequest(transport)
        #expect(request.method == "get_session_info")
        #expect(request.params == ["first", "second"])
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: #"{"active":true}"#, client: client, signer: signer))

        #expect(try await result.value == #"{"active":true}"#)
    }

    @Test("send defaults to no params")
    func sendDefaultsToNoParams() async throws {
        let (remote, transport) = try await connected()

        let result = Task { try await remote.send(RemoteSignerMethod(rawValue: "custom")) }
        let request = try await nextRequest(transport)
        #expect(request.method == "custom")
        #expect(request.params.isEmpty)
        try await transport.deliver(
            RemoteSignerFixtures.response(requestID: request.id, result: "ok", client: client, signer: signer))

        #expect(try await result.value == "ok")
    }

    @Test("send surfaces an error response as signerError")
    func sendSignerError() async throws {
        let (remote, transport) = try await connected()

        let result = Task { try await remote.send(RemoteSignerMethod(rawValue: "custom"), params: ["x"]) }
        let request = try await nextRequest(transport)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, error: "unsupported method", client: client, signer: signer))

        await #expect(throws: RemoteSignerError.signerError(message: "unsupported method")) {
            _ = try await result.value
        }
    }
}
