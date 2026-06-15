import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Direct Message Routing Tests (NIP-17, kind 10050)")
struct DirectMessageRoutingTests {

    private let inboxURL = URL(string: "wss://inbox.example.com")!
    private let absentURL = URL(string: "wss://absent.example.com")!

    // MARK: - Receive side

    @Test("connectDirectMessageInboxRelays connects the user's advertised inbox relays present in the pool")
    func connectOwnInbox() async throws {
        let pool = RelayPool()
        let client = NostrClient(relayPool: pool, gossipPolicy: .requirePresent)
        try await client.setPrivateKey(String(repeating: "1", count: 64))

        // Advertise (and cache) the user's own DM inbox relays. Empty pool: publish no-ops, but caches.
        try await client.publishDirectMessageRelayList(
            relays: ["wss://inbox.example.com", "wss://absent.example.com"]
        )
        // Only inbox.example.com is present in the pool.
        await pool.addRelay(url: inboxURL)

        let connected = try await client.connectDirectMessageInboxRelays()
        // requirePresent: only the relay already in the pool is routable.
        #expect(connected == [inboxURL])
    }

    @Test("connectDirectMessageInboxRelays without a signer throws signerNotSet")
    func connectWithoutSignerThrows() async {
        let client = NostrClient()
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.connectDirectMessageInboxRelays()
        }
    }

    // MARK: - Send side (routing resolution)

    @Test("Routes to a recipient's cached DM inbox relays present in the pool")
    func routesRecipientInbox() async {
        let pool = RelayPool()
        await pool.addRelay(url: inboxURL)
        let client = NostrClient(relayPool: pool, gossipPolicy: .requirePresent)

        let recipient = "recipientpubkey"
        await client.dmRelayListStore.store(
            DirectMessageRelayList(relays: ["wss://inbox.example.com", "wss://absent.example.com"]),
            createdAt: 1,
            for: recipient
        )

        // sendDirectMessage routes the recipient copy through this resolution.
        let targets = await client.connectedDirectMessageInboxRelays(for: recipient)
        #expect(targets == [inboxURL])
    }

    @Test("Resolving an unknown pubkey on an empty pool returns no relays")
    func unknownPubkeyEmptyPoolReturnsEmpty() async {
        // No connected relay to query, so discovery is skipped and nothing resolves —
        // the caller then falls back to the full pool.
        let client = NostrClient()
        let targets = await client.connectedDirectMessageInboxRelays(for: "nobody")
        #expect(targets.isEmpty)
    }

    @Test("A recipient with an empty DM relay list resolves to no relays (pool fallback)")
    func recipientWithEmptyListResolvesEmpty() async {
        let client = NostrClient()
        let recipient = "recipientpubkey"
        // The recipient advertised a kind 10050 with no relays; routing resolves to nothing,
        // so the caller falls back to the full pool.
        await client.dmRelayListStore.store(
            DirectMessageRelayList(relays: []), createdAt: 1, for: recipient
        )

        let targets = await client.connectedDirectMessageInboxRelays(for: recipient)
        #expect(targets.isEmpty)
    }

    @Test("sendDirectMessage falls back to the pool when no DM relay list is known")
    func sendFallsBackToPool() async throws {
        let client = NostrClient()
        try await client.setPrivateKey(String(repeating: "1", count: 64))
        let recipient = try KeyPair()

        // Empty pool, no cached lists: both copies fall back to the (empty) pool — no statuses, no throw.
        let result = try await client.sendDirectMessage("hi", to: recipient.publicKeyHex)
        #expect(result.recipientPublishResult?.statuses.isEmpty == true)
        #expect(result.selfCopyPublishResult?.statuses.isEmpty == true)
    }
}
