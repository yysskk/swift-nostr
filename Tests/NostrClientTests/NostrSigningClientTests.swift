import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A ``NostrSigning`` that signs with a held key but reports its public key asynchronously —
/// it stands in for a remote NIP-46 signer in a target that does not depend on NostrConnect.
private struct MockRemoteSigner: NostrSigning {
    let keyPair: KeyPair

    var publicKey: String {
        get async throws { keyPair.publicKeyHex }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        try EventSigner(keyPair: keyPair).sign(event)
    }

    func nip44Encrypt(_ plaintext: String, to recipientPubkey: String) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Encrypt(plaintext, to: recipientPubkey)
    }

    func nip44Decrypt(_ ciphertext: String, from senderPubkey: String) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Decrypt(ciphertext, from: senderPubkey)
    }
}

@Suite("NostrClient NostrSigning Tests")
struct NostrSigningClientTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    /// Builds a client whose single relay speaks to a test-controlled socket, so signing and
    /// authentication can be exercised without a live network.
    private func makeClient() -> (NostrClient, MockWebSocketSession) {
        let mock = MockWebSocketSession()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { mock })
        )
        return (NostrClient(relayPool: pool), mock)
    }

    private func unsignedNote(pubkey: String, content: String) -> UnsignedEvent {
        UnsignedEvent(pubkey: pubkey, kind: .textNote, content: content)
    }

    // MARK: - Setting a remote signer

    @Test("setting a remote signer caches its public key and reports a signer")
    func remoteSignerSetsPublicKey() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()

        await #expect(client.publicKey == nil)
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)

        #expect(await client.publicKey == keyPair.publicKeyHex)
        #expect(await client.hasSigner)
        #expect(try await client.npub == keyPair.npub)
    }

    // MARK: - sign(_:) through both paths

    @Test("sign(_:) with a remote signer returns a verifying event authored by the remote key")
    func remoteSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let signed = try await client.sign(unsignedNote(pubkey: keyPair.publicKeyHex, content: "hello"))

        #expect(signed.pubkey == keyPair.publicKeyHex)
        #expect(signed.kind == .textNote)
        #expect(signed.content == "hello")
        #expect(try signed.verify())
    }

    @Test("sign(_:) with a local signer returns a verifying event")
    func localSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        await client.setSigner(EventSigner(keyPair: keyPair))

        let signed = try await client.sign(unsignedNote(pubkey: keyPair.publicKeyHex, content: "hi"))

        #expect(signed.pubkey == keyPair.publicKeyHex)
        #expect(signed.content == "hi")
        #expect(try signed.verify())
    }

    @Test("sign(_:) without a signer throws signerNotSet")
    func signWithoutSignerThrows() async throws {
        let (client, _) = makeClient()
        let pubkey = try KeyPair().publicKeyHex

        await #expect(throws: NostrError.signerNotSet) {
            try await client.sign(self.unsignedNote(pubkey: pubkey, content: "x"))
        }
    }

    // MARK: - The convenience helpers work with a remote signer

    @Test("a convenience publish helper signs and publishes with a remote signer")
    func remoteSignerDrivesConvenienceHelper() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let keyPair = try KeyPair()
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.publishTextNote(content: "signed by my bunker")
        }

        #expect(published.event.kind == .textNote)
        #expect(published.event.pubkey == keyPair.publicKeyHex)
        #expect(published.event.content == "signed by my bunker")
        #expect(try published.event.verify())
        await client.disconnect()
    }

    @Test("a direct-message helper gift-wraps and delivers with a remote signer")
    func remoteSignerDrivesDirectMessageHelper() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let sender = try KeyPair()
        let recipient = try KeyPair()
        try await client.setSigner(MockRemoteSigner(keyPair: sender) as any NostrSigning)
        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: sender.publicKeyHex)
        await client.dmRelayListStore.markNoList(for: recipient.publicKeyHex)

        // Two EVENT frames: the recipient gift wrap and the self-copy gift wrap.
        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.sendDirectMessage("wrapped by my bunker", to: recipient.publicKeyHex)
        }

        #expect(result.recipientGiftWrap.kind == .giftWrap)
        // The seal inside is authored by the remote signer's user key, and the recipient
        // reads the message with nothing but their own key.
        let message = try await DirectMessageParser(signer: EventSigner(keyPair: recipient))
            .parse(result.recipientGiftWrap)
        #expect(message.content == "wrapped by my bunker")
        #expect(message.senderPubkey == sender.publicKeyHex)
        await client.disconnect()
    }

    @Test("a NIP-51 list round-trips its private items through a remote signer")
    func remoteSignerSealsPrivateListItems() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let keyPair = try KeyPair()
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let list = NostrList(
            kind: .muteList,
            publicItems: [.pubkey(String(repeating: "a", count: 64))],
            privateItems: [.pubkey(String(repeating: "b", count: 64))]
        )

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.publishList(list)
        }

        #expect(published.event.kind == .muteList)
        #expect(!published.event.content.isEmpty)
        // Only the author's key opens the private items; the remote signer sealed them.
        let opened = try EventSigner(keyPair: keyPair).openList(published.event)
        #expect(opened.privateItems == list.privateItems)
        #expect(opened.publicItems == list.publicItems)
        await client.disconnect()
    }

    // MARK: - The local path is unchanged

    @Test("setSigner(EventSigner) still reports the right public key and npub")
    func localSignerSmokeTest() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        await client.setSigner(EventSigner(keyPair: keyPair))

        #expect(await client.hasSigner)
        #expect(await client.publicKey == keyPair.publicKeyHex)
        #expect(try await client.npub == keyPair.npub)
    }

    // MARK: - Remote signer answers a NIP-42 AUTH challenge

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    @Test("a remote signer answers an AUTH challenge with a kind-22242 event")
    func remoteSignerAnswersAuthChallenge() async throws {
        let (client, mock) = makeClient()
        let keyPair = try KeyPair()
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","remote-challenge"]"#))

        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try NIP42TestSupport.sentAuthEvent(in: mock)

        #expect(sent.kind == .clientAuthentication)
        #expect(sent.pubkey == keyPair.publicKeyHex)
        #expect(sent.firstTagValue(named: "relay") == relayURL.absoluteString)
        #expect(sent.firstTagValue(named: "challenge") == "remote-challenge")
        #expect(try sent.verify())

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await pollUntil { await connection.isAuthenticated }
        await client.disconnect()
    }

    @Test("manual authenticate(relayURL:) works with a remote signer")
    func remoteSignerManualAuthenticate() async throws {
        let (client, mock) = makeClient()
        let keyPair = try KeyPair()
        await client.setAuthenticationMode(.manual)
        try await client.setSigner(MockRemoteSigner(keyPair: keyPair) as any NostrSigning)
        try await client.connect(to: [relayURL.absoluteString])

        mock.deliver(.string(#"["AUTH","manual-challenge"]"#))
        let connection = try #require(await client.relayPool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        // Manual mode: the remote signer must still be able to answer via activeSign.
        // authenticate(relayURL:) awaits the relay's OK, so drive it concurrently and settle it.
        let authTask = Task { try await client.authenticate(relayURL: relayURL) }
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try NIP42TestSupport.sentAuthEvent(in: mock)
        #expect(sent.kind == .clientAuthentication)
        #expect(sent.pubkey == keyPair.publicKeyHex)
        #expect(sent.firstTagValue(named: "challenge") == "manual-challenge")
        #expect(try sent.verify())

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await authTask.value
        await client.disconnect()
    }
}
