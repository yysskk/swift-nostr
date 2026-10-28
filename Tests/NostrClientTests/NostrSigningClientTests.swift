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
        RelayConnectionConfig(connectionTimeout: .seconds(1), pingInterval: .seconds(60), reconnect: nil)
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
        let keyPair = KeyPair()

        await #expect(client.identity.publicKey == nil)
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))

        #expect(await client.identity.publicKey == keyPair.publicKey)
        #expect(await client.hasSigner)
    }

    // MARK: - sign(_:) through both paths

    @Test("sign(_:) with a remote signer returns a verifying event authored by the remote key")
    func remoteSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))

        var template = EventTemplate.textNote("hello", tags: [.hashtag("nostr")])
        template.createdAt = Timestamp(rawValue: 1_700_000_000)
        let signed = try await client.identity.sign(template)

        #expect(signed.publicKey == keyPair.publicKey)
        #expect(signed.kind == .textNote)
        #expect(signed.content == "hello")
        #expect(signed.tags.map(\.rawArray) == [["t", "nostr"]])
        #expect(signed.createdAt == template.createdAt)
        try signed.verify()
    }

    @Test("sign(_:) with a local signer returns a verifying event")
    func localSignerSigns() async throws {
        let (client, _) = makeClient()
        let keyPair = KeyPair()
        try await client.identity.setSigner(EventSigner(keyPair: keyPair))

        let signed = try await client.identity.sign(.textNote("hi"))

        #expect(signed.publicKey == keyPair.publicKey)
        #expect(signed.content == "hi")
        try signed.verify()
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
        let sender = KeyPair()
        let peer = KeyPair()
        try await client.identity.setSigner(EventSigner(keyPair: sender))

        let payload = try await client.identity.nip44Encrypt("to the peer", to: peer.publicKey)
        #expect(try EventSigner(keyPair: peer).nip44Decrypt(payload, from: sender.publicKey) == "to the peer")

        let reply = try EventSigner(keyPair: peer).nip44Encrypt("from the peer", to: sender.publicKey)
        #expect(try await client.identity.nip44Decrypt(reply, from: peer.publicKey) == "from the peer")
    }

    @Test("nip44Encrypt/nip44Decrypt with a remote signer round-trip with a peer's key")
    func remoteSignerNIP44RoundTrip() async throws {
        let (client, _) = makeClient()
        let sender = KeyPair()
        let peer = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: sender))

        let payload = try await client.identity.nip44Encrypt("to the peer", to: peer.publicKey)
        #expect(try EventSigner(keyPair: peer).nip44Decrypt(payload, from: sender.publicKey) == "to the peer")

        let reply = try EventSigner(keyPair: peer).nip44Encrypt("from the peer", to: sender.publicKey)
        #expect(try await client.identity.nip44Decrypt(reply, from: peer.publicKey) == "from the peer")
    }

    @Test("nip44Encrypt/nip44Decrypt without a signer throw signerNotSet")
    func nip44WithoutSignerThrows() async throws {
        let (client, _) = makeClient()
        let peer = KeyPair()
        let payload = try EventSigner(keyPair: peer).nip44Encrypt("x", to: KeyPair().publicKey)

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
        let keyPair = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "signed by my bunker")
        }

        #expect(published.event.kind == .textNote)
        #expect(published.event.publicKey == keyPair.publicKey)
        #expect(published.event.content == "signed by my bunker")
        try published.event.verify()
        await client.relays.disconnect()
    }

    @Test("a direct-message helper gift-wraps and delivers with a remote signer")
    func remoteSignerDrivesDirectMessageHelper() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let sender = KeyPair()
        let recipient = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: sender))
        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: sender.publicKey)
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)

        // Two EVENT frames: the recipient gift wrap and the self-copy gift wrap.
        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.send("wrapped by my bunker", to: recipient.publicKey)
        }

        #expect(result.message.recipientGiftWrap.kind == .giftWrap)
        // The seal inside is authored by the remote signer's user key, and the recipient
        // reads the message with nothing but their own key.
        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let message = try #require(await recipientParser.open(result.message.recipientGiftWrap).message)
        #expect(message.content == "wrapped by my bunker")
        #expect(message.senderPublicKey == sender.publicKey)
        await client.relays.disconnect()
    }

    @Test("a NIP-51 list round-trips its private items through a remote signer")
    func remoteSignerSealsPrivateListItems() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let keyPair = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))

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

    // MARK: - Setting a local signer

    @Test("setting a local signer caches its public key and reports a signer")
    func localSignerSetsPublicKey() async throws {
        let (client, _) = makeClient()
        let keyPair = KeyPair()
        try await client.identity.setSigner(EventSigner(keyPair: keyPair))

        #expect(await client.hasSigner)
        #expect(await client.identity.publicKey == keyPair.publicKey)
    }

    @Test("setting a signer replaces the current one")
    func setSignerReplacesCurrentSigner() async throws {
        let (client, _) = makeClient()
        let remote = KeyPair()
        let local = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: remote))
        try await client.identity.setSigner(EventSigner(keyPair: local))

        let signed = try await client.identity.sign(.textNote("replaced"))

        #expect(await client.identity.publicKey == local.publicKey)
        #expect(signed.publicKey == local.publicKey)
        try signed.verify()
    }

    // MARK: - Removing the signer

    @Test(
        "removeSigner clears the public key and makes signing throw signerNotSet",
        arguments: [true, false])
    func removeSignerClearsSigner(remote: Bool) async throws {
        let (client, _) = makeClient()
        let keyPair = KeyPair()
        if remote {
            try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))
        } else {
            try await client.identity.setSigner(EventSigner(keyPair: keyPair))
        }

        await client.identity.removeSigner()

        #expect(await client.identity.publicKey == nil)
        #expect(await !client.hasSigner)
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.identity.sign(.textNote("unsigned"))
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.identity.nip44Encrypt("sealed", to: keyPair.publicKey)
        }
    }

    @Test("removeSigner is idempotent, including on a client that never had a signer")
    func removeSignerIsIdempotent() async throws {
        let (client, _) = makeClient()
        await client.identity.removeSigner()
        #expect(await client.identity.publicKey == nil)

        try await client.identity.setSigner(EventSigner(keyPair: KeyPair()))
        await client.identity.removeSigner()
        await client.identity.removeSigner()

        #expect(await client.identity.publicKey == nil)
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.identity.sign(.textNote("unsigned"))
        }
    }

    // MARK: - Overlapping calls: the last to start wins

    @Test("removeSigner during a remote setSigner's key lookup is not undone by it")
    func removeSignerSupersedesPendingRemoteSet() async throws {
        let (client, _) = makeClient()
        let gate = PublicKeyGate()
        let remote = GatedRemoteSigner(keyPair: KeyPair(), gate: gate)
        let identity = client.identity
        let pendingSet = Task { try await identity.setSigner(remote) }
        await gate.untilRequested()

        await client.identity.removeSigner()
        await gate.open()
        try await pendingSet.value

        #expect(await client.identity.publicKey == nil)
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.identity.sign(.textNote("unsigned"))
        }
    }

    @Test("a local setSigner during a remote setSigner's key lookup is not overwritten by it")
    func laterSetSupersedesPendingRemoteSet() async throws {
        let (client, _) = makeClient()
        let gate = PublicKeyGate()
        let remote = GatedRemoteSigner(keyPair: KeyPair(), gate: gate)
        let local = KeyPair()
        let identity = client.identity
        let pendingSet = Task { try await identity.setSigner(remote) }
        await gate.untilRequested()

        try await client.identity.setSigner(EventSigner(keyPair: local))
        await gate.open()
        try await pendingSet.value

        let signed = try await client.identity.sign(.textNote("local"))
        #expect(await client.identity.publicKey == local.publicKey)
        #expect(signed.publicKey == local.publicKey)
    }

    @Test("a signer set after removeSigner signs again")
    func setSignerAfterRemoveSigner() async throws {
        let (client, _) = makeClient()
        let keyPair = KeyPair()
        try await client.identity.setSigner(EventSigner(keyPair: KeyPair()))
        await client.identity.removeSigner()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))

        let signed = try await client.identity.sign(.textNote("back"))

        #expect(await client.identity.publicKey == keyPair.publicKey)
        #expect(signed.publicKey == keyPair.publicKey)
        try signed.verify()
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
        let keyPair = KeyPair()
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))
        try await client.relays.connect(to: [relayURL])

        mock.deliver(.string(#"["AUTH","remote-challenge"]"#))

        let connection = try #require(await client.relays.pool.relay(for: relayURL))
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try NIP42TestSupport.sentAuthEvent(in: mock)

        #expect(sent.kind == .clientAuthentication)
        #expect(sent.publicKey == keyPair.publicKey)
        #expect(sent.firstTagValue(named: "relay") == relayURL.description)
        #expect(sent.firstTagValue(named: "challenge") == "remote-challenge")
        try sent.verify()

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await pollUntil { await connection.isAuthenticated }
        await client.relays.disconnect()
    }

    @Test("manual authenticate(relayURL:) works with a remote signer")
    func remoteSignerManualAuthenticate() async throws {
        let (client, mock) = makeClient()
        let keyPair = KeyPair()
        await client.identity.setAuthenticationMode(.manual)
        try await client.identity.setSigner(StubRemoteSigner(keyPair: keyPair))
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
        try sent.verify()

        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await authTask.value
        await client.relays.disconnect()
    }
}
