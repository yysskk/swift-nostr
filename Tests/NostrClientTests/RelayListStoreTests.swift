import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Relay List Store Tests (NIP-65 gossip)")
struct RelayListStoreTests {

    private func makeStore(policy: GossipRelayPolicy = .requirePresent) -> RelayListStore {
        RelayListStore(pool: RelayPool(), policy: policy)
    }

    @Test("Newer relay list wins (replaceable event)")
    func newerWins() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        let listA = RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://a.example.com")!)])
        let listB = RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://b.example.com")!)])
        let listC = RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://c.example.com")!)])

        await store.store(listA, createdAt: Timestamp(rawValue: 100), for: publicKey)
        await store.store(listB, createdAt: Timestamp(rawValue: 50), for: publicKey)  // older → ignored
        var cached = await store.cachedList(for: publicKey)
        #expect(cached?.entries.first?.url == RelayURL("wss://a.example.com"))

        await store.store(listC, createdAt: Timestamp(rawValue: 200), for: publicKey)  // newer → wins
        cached = await store.cachedList(for: publicKey)
        #expect(cached?.entries.first?.url == RelayURL("wss://c.example.com"))
    }

    @Test("Equal createdAt keeps existing entry")
    func equalCreatedAtKeepsExisting() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(
            RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://a.example.com")!)]),
            createdAt: Timestamp(rawValue: 100),
            for: publicKey
        )
        await store.store(
            RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://b.example.com")!)]),
            createdAt: Timestamp(rawValue: 100),
            for: publicKey
        )

        let cached = await store.cachedList(for: publicKey)
        #expect(cached?.entries.first?.url == RelayURL("wss://a.example.com"))
    }

    @Test("Resolves write and read relay URLs")
    func writeReadURLResolution() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: RelayURL("wss://both.example.com")!, usage: .readWrite),
            RelayListEntry(url: RelayURL("wss://read.example.com")!, usage: .read),
            RelayListEntry(url: RelayURL("wss://write.example.com")!, usage: .write),
        ])
        await store.store(list, createdAt: Timestamp(rawValue: 1), for: publicKey)

        let writeURLs = await store.writeRelayURLs(for: publicKey)
        let readURLs = await store.readRelayURLs(for: publicKey)

        let expectedWrite: Set<RelayURL> = [
            RelayURL("wss://both.example.com")!,
            RelayURL("wss://write.example.com")!,
        ]
        let expectedRead: Set<RelayURL> = [
            RelayURL("wss://both.example.com")!,
            RelayURL("wss://read.example.com")!,
        ]
        #expect(writeURLs == expectedWrite)
        #expect(readURLs == expectedRead)
    }

    @Test("Unknown public key resolves to empty relay sets")
    func unknownPublicKeyResolvesEmpty() async {
        let store = makeStore()
        let writeURLs = await store.writeRelayURLs(for: PublicKey.fixture("nobody"))
        let readURLs = await store.readRelayURLs(for: PublicKey.fixture("nobody"))
        #expect(writeURLs.isEmpty)
        #expect(readURLs.isEmpty)
    }

    @Test("Ingest a kind 10002 event")
    func ingestEvent() async throws {
        let store = makeStore()
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = signer.sign(
            .relayListMetadata(
                RelayListMetadata(entries: [RelayListEntry(url: RelayURL("wss://a.example.com")!, usage: .write)]))
        )
        let ingested = await store.ingest(event)
        #expect(ingested != nil)

        let cached = await store.cachedList(for: keyPair.publicKey)
        #expect(cached?.writeRelays == [RelayURL("wss://a.example.com")!])
    }

    @Test("Ingest ignores non-10002 event")
    func ingestIgnoresOtherKind() async throws {
        let store = makeStore()
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = signer.sign(.textNote("Hello"))
        let ingested = await store.ingest(textNote)
        #expect(ingested == nil)
    }

    @Test("requirePresent policy never opens absent relays")
    func requirePresentIgnoresAbsent() async {
        let store = makeStore(policy: .requirePresent)
        let urls: Set<RelayURL> = [RelayURL("wss://absent.example.com")!]
        let available = await store.ensureConnected(urls)
        #expect(available.isEmpty)
    }

    @Test("addAndConnect reuses the pooled connection for an alternate spelling of its URL")
    func addAndConnectReusesPooledRelayAcrossSpellings() async throws {
        let socketCount = SocketCount()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: {
                socketCount.increment()
                return MockWebSocketSession()
            })
        )
        let store = RelayListStore(pool: pool, policy: .addAndConnect)
        let connection = await pool.add(RelayURL("wss://relay.example.com")!)
        try await connection.connect()
        #expect(socketCount.current == 1)

        // The same relay spelled with a trailing slash must route to the existing
        // connection instead of opening a duplicate socket, and the returned set
        // carries the canonical spelling, not the input's.
        let alternate = RelayURL("wss://relay.example.com/")!
        let available = await store.ensureConnected([alternate])

        #expect(available == [RelayURL("wss://relay.example.com")!])
        #expect(socketCount.current == 1)
        #expect(await pool.relayCount == 1)
        await pool.disconnect()
    }

    @Test("addAndConnect returns canonical URLs for relays it adds")
    func addAndConnectReturnsCanonicalURLs() async throws {
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        )
        let store = RelayListStore(pool: pool, policy: .addAndConnect)

        let available = await store.ensureConnected([RelayURL("wss://New.Example.com/")!])

        #expect(available == [RelayURL("wss://new.example.com")!])
        #expect(await pool.relay(for: RelayURL("wss://new.example.com")!) != nil)
        await pool.disconnect()
    }

}

/// Counts how many sockets a mock factory has handed out.
private final class SocketCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
