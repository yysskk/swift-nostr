import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("NostrClient NostrSigning Tests")
struct NostrSigningClientTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: .seconds(1), pingInterval: .seconds(60), autoReconnect: false)
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

    // MARK: - Setting a remote signer

    @Test("setting a remote signer caches its public key and reports a signer")
    func remoteSignerSetsPublicKey() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()

        await #expect(client.identity.publicKey == nil)
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)

        #expect(await client.identity.publicKey == keyPair.publicKey)
        #expect(await client.hasSigner)
    }

    // MARK: - sign(_:) through both paths

    @Test("sign(_:) with a remote signer returns a verifying event authored by the remote key")
    func remoteSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)

        var template = EventTemplate.textNote("hello", tags: [.hashtag("nostr")])
        template.createdAt = Timestamp(rawValue: 1_700_000_000)
        let signed = try await client.identity.sign(template)

        #expect(signed.publicKey == keyPair.publicKey)
        #expect(signed.kind == .textNote)
        #expect(signed.content == "hello")
        #expect(signed.tags == [["t", "nostr"]])
        #expect(signed.createdAt == template.createdAt)
        #expect(try signed.verify())
    }

    @Test("sign(_:) with a local signer returns a verifying event")
    func localSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        await client.identity.setSigner(EventSigner(keyPair: keyPair))

        let signed = try await client.identity.sign(.textNote("hi"))

        #expect(signed.publicKey == keyPair.publicKey)
        #expect(signed.content == "hi")
        #expect(try signed.verify())
    }

    @Test("sign(_:) without a signer throws signerNotSet")
    func signWithoutSignerThrows() async throws {
        let (client, _) = makeClient()

        await #expect(throws: NostrClient.Error.signerNotSet) {
            try await client.identity.sign(.textNote("x"))
        }
    }

    // MARK: - NIP-44 through both paths

    @Test("nip44Encrypt/nip44Decrypt with a local signer round-trip with a peer's key")
    func localSignerNIP44RoundTrip() async throws {
        let (client, _) = makeClient()
        let sender = try KeyPair()
        let peer = try KeyPair()
        await client.identity.setSigner(EventSigner(keyPair: sender))

        let payload = try await client.identity.nip44Encrypt("to the peer", to: peer.publicKey)
        #expect(try EventSigner(keyPair: peer).nip44Decrypt(payload, from: sender.publicKey) == "to the peer")

        let reply = try EventSigner(keyPair: peer).nip44Encrypt("from the peer", to: sender.publicKey)
        #expect(try await client.identity.nip44Decrypt(reply, from: peer.publicKey) == "from the peer")
    }

    @Test("nip44Encrypt/nip44Decrypt with a remote signer round-trip with a peer's key")
    func remoteSignerNIP44RoundTrip() async throws {
        let (client, _) = makeClient()
        let sender = try KeyPair()
        let peer = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: sender) as any NostrSigning)

        let payload = try await client.identity.nip44Encrypt("to the peer", to: peer.publicKey)
        #expect(try EventSigner(keyPair: peer).nip44Decrypt(payload, from: sender.publicKey) == "to the peer")

        let reply = try EventSigner(keyPair: peer).nip44Encrypt("from the peer", to: sender.publicKey)
        #expect(try await client.identity.nip44Decrypt(reply, from: peer.publicKey) == "from the peer")
    }

    @Test("nip44Encrypt/nip44Decrypt without a signer throw signerNotSet")
    func nip44WithoutSignerThrows() async throws {
        let (client, _) = makeClient()
        let peer = try KeyPair()
        let payload = try EventSigner(keyPair: peer).nip44Encrypt("x", to: try KeyPair().publicKey)

        await #expect(throws: NostrClient.Error.signerNotSet) {
            try await client.identity.nip44Encrypt("x", to: peer.publicKey)
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            try await client.identity.nip44Decrypt(payload, from: peer.publicKey)
        }
    }

    // MARK: - The convenience helpers work with a remote signer

    @Test("a convenience publish helper signs and publishes with a remote signer")
    func remoteSignerDrivesConvenienceHelper() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let keyPair = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "signed by my bunker")
        }

        #expect(published.event.kind == .textNote)
        #expect(published.event.publicKey == keyPair.publicKey)
        #expect(published.event.content == "signed by my bunker")
        #expect(try published.event.verify())
        await client.relays.disconnect()
    }

    @Test("a direct-message helper gift-wraps and delivers with a remote signer")
    func remoteSignerDrivesDirectMessageHelper() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let sender = try KeyPair()
        let recipient = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: sender) as any NostrSigning)
        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: sender.publicKey)
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)

        // Two EVENT frames: the recipient gift wrap and the self-copy gift wrap.
        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.send("wrapped by my bunker", to: recipient.publicKey)
        }

        #expect(result.recipientGiftWrap.kind == .giftWrap)
        // The seal inside is authored by the remote signer's user key, and the recipient
        // reads the message with nothing but their own key.
        let message = try await DirectMessageParser(signer: EventSigner(keyPair: recipient))
            .parse(result.recipientGiftWrap)
        #expect(message.content == "wrapped by my bunker")
        #expect(message.senderPublicKey == sender.publicKey)
        await client.relays.disconnect()
    }

    @Test("a NIP-51 list round-trips its private items through a remote signer")
    func remoteSignerSealsPrivateListItems() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let keyPair = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)

        let list = NostrList(
            kind: .muteList,
            publicItems: [.publicKey(.fixture("public"))],
            privateItems: [.publicKey(.fixture("private"))]
        )

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.lists.publish(list)
        }

        #expect(published.event.kind == .muteList)
        #expect(!published.event.content.isEmpty)
        // Only the author's key opens the private items; the remote signer sealed them.
        let opened = try await NostrList(event: published.event, decryptingWith: EventSigner(keyPair: keyPair))
        #expect(opened.privateItems == list.privateItems)
        #expect(opened.publicItems == list.publicItems)
        await client.relays.disconnect()
    }

    // MARK: - The local path is unchanged

    @Test("identity.setSigner(EventSigner) still reports the right public key")
    func localSignerSmokeTest() async throws {
        let (client, _) = makeClient()
        let keyPair = try KeyPair()
        await client.identity.setSigner(EventSigner(keyPair: keyPair))

        #expect(await client.hasSigner)
        #expect(await client.identity.publicKey == keyPair.publicKey)
    }

    // MARK: - Remote signer answers a NIP-42 AUTH challenge

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RelayConnection.Error.timedOut
    }

    @Test("a remote signer answers an AUTH challenge with a kind-22242 event")
    func remoteSignerAnswersAuthChallenge() async throws {
        let (client, mock) = makeClient()
        let keyPair = try KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)
        try await client.relays.connect(to: [relayURL])

        mock.deliver(.string(#"["AUTH","remote-challenge"]"#))

        let connection = try #require(await client.relays.pool.relay(for: relayURL))
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try NIP42TestSupport.sentAuthEvent(in: mock)

        #expect(sent.kind == .clientAuthentication)
        #expect(sent.publicKey == keyPair.publicKey)
        #expect(sent.firstTagValue(named: "relay") == relayURL.description)
        #expect(sent.firstTagValue(named: "challenge") == "remote-challenge")
        #expect(try sent.verify())

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await pollUntil { await connection.isAuthenticated }
        await client.relays.disconnect()
    }

    @Test("manual authenticate(relayURL:) works with a remote signer")
    func remoteSignerManualAuthenticate() async throws {
        let (client, mock) = makeClient()
        let keyPair = try KeyPair()
        await client.identity.setAuthenticationMode(.manual)
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair) as any NostrSigning)
        try await client.relays.connect(to: [relayURL])

        mock.deliver(.string(#"["AUTH","manual-challenge"]"#))
        let connection = try #require(await client.relays.pool.relay(for: relayURL))
        try await pollUntil { await connection.authenticationChallenge != nil }

        // Manual mode: the remote signer must still be able to answer through the client.
        // authenticate(relayURL:) awaits the relay's OK, so drive it concurrently and settle it.
        let authTask = Task { try await client.identity.authenticate(relayURL: relayURL) }
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try NIP42TestSupport.sentAuthEvent(in: mock)
        #expect(sent.kind == .clientAuthentication)
        #expect(sent.publicKey == keyPair.publicKey)
        #expect(sent.firstTagValue(named: "challenge") == "manual-challenge")
        #expect(try sent.verify())

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await authTask.value
        await client.relays.disconnect()
    }
}
