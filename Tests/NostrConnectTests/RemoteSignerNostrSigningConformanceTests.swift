import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSigner NostrSigning Conformance Tests")
struct RemoteSignerNostrSigningConformanceTests {
    private let client: KeyPair
    private let signer: KeyPair

    init() throws {
        self.client = try KeyPair()
        self.signer = try KeyPair()
    }

    /// A connected ``RemoteSigner`` with its fake transport, ready for command tests.
    private func connected() async throws -> (RemoteSigner, FakeRemoteSignerTransport) {
        let transport = FakeRemoteSignerTransport()
        let remote = try RemoteSigner(
            bunker: RemoteSignerFixtures.bunker(signer: signer),
            clientKeyPair: client,
            transport: transport,
            config: .init(requestTimeout: 1))
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

    @Test("RemoteSigner is usable as any NostrSigning")
    func remoteSignerConformsToNostrSigning() async throws {
        let (remote, _) = try await connected()
        // Compile-level check: a RemoteSigner binds to the existential without adaptation.
        let _: any NostrSigning = remote
    }

    @Test("publicKey through any NostrSigning returns the user pubkey from get_public_key")
    func publicKeyThroughProtocol() async throws {
        let (remote, transport) = try await connected()
        let signing: any NostrSigning = remote

        let resolved = Task { try await signing.publicKey }
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.getPublicKey.rawValue)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: "userpubhex", client: client, signer: signer))

        #expect(try await resolved.value == "userpubhex")
    }

    @Test("signing through any NostrSigning round-trips a verifiable event")
    func signThroughProtocol() async throws {
        let (remote, transport) = try await connected()
        let signing: any NostrSigning = remote
        let unsigned = UnsignedEvent(
            pubkey: signer.publicKeyHex, createdAt: 1000, kind: .textNote, content: "hello via protocol")

        async let signed = signing.sign(unsigned)
        let request = try await nextRequest(transport)
        #expect(request.method == RemoteSignerMethod.signEvent.rawValue)

        let toSign = try RemoteSignerFixtures.unsignedEvent(from: request, author: signer.publicKeyHex)
        let json = try RemoteSignerFixtures.signedEventJSON(toSign, signer: signer)
        try await transport.deliver(
            RemoteSignerFixtures.response(
                requestID: request.id, result: json, client: client, signer: signer))

        let event = try await signed
        #expect(try event.verify())
        #expect(event.kind == .textNote)
        #expect(event.content == "hello via protocol")
        #expect(event.pubkey == signer.publicKeyHex)
    }
}
