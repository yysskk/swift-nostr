import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Gift-Wrapped Rumor Delivery Tests (messages.sendGiftWrapped)")
struct GiftWrappedRumorDeliveryTests {

    private let customKind = Event.Kind(rawValue: 30_999)
    private let senderKey = String(repeating: "1", count: 64)

    private func makeRumor(publicKey: PublicKey, recipient: PublicKey) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey, kind: customKind,
            tags: [.publicKey(recipient), .hashtag("friend-request")],
            content: "{\"bundle\":\"abc\"}"
        )
    }

    @Test("a custom-kind rumor reaches the recipient and the self-copy via the pool fallback")
    func deliversCustomKindRumor() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(senderKey)
        let sender = try KeyPair(privateKeyHex: senderKey)
        let recipient = try KeyPair()
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)
        await client.dmRelayListStore.markNoList(for: sender.publicKey)
        let rumor = makeRumor(publicKey: sender.publicKey, recipient: recipient.publicKey)

        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.sendGiftWrapped(rumor, to: recipient.publicKey)
        }

        #expect(result.rumor.kind == customKind)
        #expect(result.rumor.signature == nil)
        #expect(result.rumor.id == (try rumor.computedID))

        let received = try await GiftWrap.unwrap(
            giftWrap: result.recipientGiftWrap, recipient: EventSigner(keyPair: recipient))
        #expect(received.senderPublicKey == sender.publicKey)
        #expect(received.event.id == result.rumor.id)
        #expect(received.event.kind == customKind)
        #expect(received.event.content == rumor.content)
        #expect(received.event.tags == rumor.tags)
        #expect(received.event.signature == nil)

        let selfCopy = try await GiftWrap.unwrap(
            giftWrap: result.selfGiftWrap, recipient: EventSigner(keyPair: sender))
        #expect(selfCopy.event.id == result.rumor.id)

        let poolRelay = ConnectedClientFixture.defaultRelayURL
        #expect(result.recipientPublishResult?.acceptedRelays == [poolRelay])
        #expect(result.selfCopyPublishResult?.acceptedRelays == [poolRelay])
        await client.relays.disconnect()
    }

    @Test("the recipient copy is routed to the recipient's cached DM inbox relays")
    func routesToRecipientInbox() async throws {
        let poolURL = RelayURL("wss://pool.example.com")!
        let inboxURL = RelayURL("wss://inbox.example.com")!
        let sockets = [MockWebSocketSession(), MockWebSocketSession()]
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets[counter.next()] })
        )
        try await pool.addRelay(poolURL).connect()
        try await pool.addRelay(inboxURL).connect()
        let client = NostrClient(relayPool: pool, gossipPolicy: .requirePresent)
        try await client.identity.setPrivateKey(senderKey)
        let sender = try KeyPair(privateKeyHex: senderKey)
        let recipient = try KeyPair()
        await client.dmRelayListStore.store(
            DirectMessageRelayList(relays: [inboxURL]), createdAt: Timestamp(rawValue: 1), for: recipient.publicKey)
        // The sender advertised no list, so the self-copy falls back to the whole pool.
        await client.dmRelayListStore.markNoList(for: sender.publicKey)
        let rumor = makeRumor(publicKey: sender.publicKey, recipient: recipient.publicKey)

        let task = Task { try await client.messages.sendGiftWrapped(rumor, to: recipient.publicKey) }
        // The inbox relay receives both wraps; the other pool relay only the self-copy.
        try await PublishAckSupport.acknowledgePublish(on: sockets[1], frame: 0)
        try await PublishAckSupport.acknowledgePublish(on: sockets[1], frame: 1)
        try await PublishAckSupport.acknowledgePublish(on: sockets[0], frame: 0)
        let result = try await task.value

        let poolRelayIDs = try PublishAckSupport.eventFrames(in: sockets[0]).map {
            try PublishAckSupport.event(inFrame: $0).id
        }
        #expect(poolRelayIDs == [result.selfGiftWrap.id])
        #expect(result.recipientPublishResult?.acceptedRelays == [inboxURL])
        await client.relays.disconnect()
    }

    @Test("an expiration is set on both gift wraps")
    func expirationOnBothWraps() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(senderKey)
        let sender = try KeyPair(privateKeyHex: senderKey)
        let recipient = try KeyPair()
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)
        await client.dmRelayListStore.markNoList(for: sender.publicKey)
        let expiry = Timestamp(rawValue: 2_000_000_000)
        let rumor = makeRumor(publicKey: sender.publicKey, recipient: recipient.publicKey)

        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.sendGiftWrapped(rumor, to: recipient.publicKey, expiration: expiry)
        }

        #expect(result.recipientGiftWrap.expiration == expiry)
        #expect(result.selfGiftWrap.expiration == expiry)
        #expect(result.rumor.expiration == nil)
        await client.relays.disconnect()
    }

    @Test("a rumor authored under another key throws invalidPublicKey and publishes nothing")
    func mismatchedPublicKeyThrows() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(senderKey)
        let recipient = try KeyPair()
        let rumor = makeRumor(publicKey: try KeyPair().publicKey, recipient: recipient.publicKey)

        await #expect(throws: NostrError.invalidPublicKey) {
            try await client.messages.sendGiftWrapped(rumor, to: recipient.publicKey)
        }
        #expect(PublishAckSupport.eventFrames(in: socket).isEmpty)
        await client.relays.disconnect()
    }

    @Test("an empty pool throws noRelaysInPool")
    func emptyPoolThrows() async throws {
        let client = NostrClient()
        try await client.identity.setPrivateKey(senderKey)
        let sender = try KeyPair(privateKeyHex: senderKey)
        let recipient = try KeyPair()
        let rumor = makeRumor(publicKey: sender.publicKey, recipient: recipient.publicKey)

        await #expect(throws: NostrError.noRelaysInPool) {
            try await client.messages.sendGiftWrapped(rumor, to: recipient.publicKey)
        }
    }

    @Test("without a signer it throws signerNotSet")
    func noSignerThrows() async throws {
        let client = NostrClient()
        let rumor = makeRumor(publicKey: try KeyPair().publicKey, recipient: try KeyPair().publicKey)

        await #expect(throws: NostrError.signerNotSet) {
            try await client.messages.sendGiftWrapped(rumor, to: try KeyPair().publicKey)
        }
    }
}

private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
