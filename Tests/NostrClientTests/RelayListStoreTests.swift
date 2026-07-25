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
        let pubkey = "pubkey1"

        let listA = RelayListMetadata(entries: [RelayListEntry(url: "wss://a.example.com")])
        let listB = RelayListMetadata(entries: [RelayListEntry(url: "wss://b.example.com")])
        let listC = RelayListMetadata(entries: [RelayListEntry(url: "wss://c.example.com")])

        await store.store(listA, createdAt: 100, for: pubkey)
        await store.store(listB, createdAt: 50, for: pubkey)  // older → ignored
        var cached = await store.cachedList(for: pubkey)
        #expect(cached?.entries.first?.url == "wss://a.example.com")

        await store.store(listC, createdAt: 200, for: pubkey)  // newer → wins
        cached = await store.cachedList(for: pubkey)
        #expect(cached?.entries.first?.url == "wss://c.example.com")
    }

    @Test("Equal createdAt keeps existing entry")
    func equalCreatedAtKeepsExisting() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.store(
            RelayListMetadata(entries: [RelayListEntry(url: "wss://a.example.com")]),
            createdAt: 100,
            for: pubkey
        )
        await store.store(
            RelayListMetadata(entries: [RelayListEntry(url: "wss://b.example.com")]),
            createdAt: 100,
            for: pubkey
        )

        let cached = await store.cachedList(for: pubkey)
        #expect(cached?.entries.first?.url == "wss://a.example.com")
    }

    @Test("Resolves write and read relay URLs")
    func writeReadURLResolution() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        let list = RelayListMetadata(entries: [
            RelayListEntry(url: "wss://both.example.com", usage: .readWrite),
            RelayListEntry(url: "wss://read.example.com", usage: .read),
            RelayListEntry(url: "wss://write.example.com", usage: .write),
        ])
        await store.store(list, createdAt: 1, for: pubkey)

        let writeURLs = await store.writeRelayURLs(for: pubkey)
        let readURLs = await store.readRelayURLs(for: pubkey)

        let expectedWrite: Set<URL> = [
            URL(string: "wss://both.example.com")!,
            URL(string: "wss://write.example.com")!,
        ]
        let expectedRead: Set<URL> = [
            URL(string: "wss://both.example.com")!,
            URL(string: "wss://read.example.com")!,
        ]
        #expect(writeURLs == expectedWrite)
        #expect(readURLs == expectedRead)
    }

    @Test("Unknown pubkey resolves to empty relay sets")
    func unknownPubkeyResolvesEmpty() async {
        let store = makeStore()
        let writeURLs = await store.writeRelayURLs(for: "nobody")
        let readURLs = await store.readRelayURLs(for: "nobody")
        #expect(writeURLs.isEmpty)
        #expect(readURLs.isEmpty)
    }

    @Test("Ingest a kind 10002 event")
    func ingestEvent() async throws {
        let store = makeStore()
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signRelayListMetadata(
            RelayListMetadata(entries: [RelayListEntry(url: "wss://a.example.com", usage: .write)])
        )
        let ingested = await store.ingest(event)
        #expect(ingested != nil)

        let cached = await store.cachedList(for: keyPair.publicKeyHex)
        #expect(cached?.writeRelays == ["wss://a.example.com"])
    }

    @Test("Ingest ignores non-10002 event")
    func ingestIgnoresOtherKind() async throws {
        let store = makeStore()
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = try signer.signTextNote(content: "Hello")
        let ingested = await store.ingest(textNote)
        #expect(ingested == nil)
    }

    @Test("requirePresent policy never opens absent relays")
    func requirePresentIgnoresAbsent() async {
        let store = makeStore(policy: .requirePresent)
        let urls: Set<URL> = [URL(string: "wss://absent.example.com")!]
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
        let connection = try await pool.addRelay(URL(string: "wss://relay.example.com")!)
        try await connection.connect()
        #expect(socketCount.current == 1)

        // The same relay spelled with a trailing slash must route to the existing
        // connection instead of opening a duplicate socket, and the returned set
        // carries the canonical spelling, not the input's.
        let alternate = URL(string: "wss://relay.example.com/")!
        let available = await store.ensureConnected([alternate])

        #expect(available == [URL(string: "wss://relay.example.com")!])
        #expect(socketCount.current == 1)
        #expect(await pool.count == 1)
        await pool.disconnectAll()
    }

    @Test("addAndConnect returns canonical URLs for relays it adds")
    func addAndConnectReturnsCanonicalURLs() async throws {
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        )
        let store = RelayListStore(pool: pool, policy: .addAndConnect)

        let available = await store.ensureConnected([URL(string: "wss://New.Example.com/")!])

        #expect(available == [URL(string: "wss://new.example.com")!])
        #expect(await pool.relay(for: URL(string: "wss://new.example.com")!) != nil)
        await pool.disconnectAll()
    }

    @Test("addAndConnect skips a URL the pool refuses without failing the route")
    func addAndConnectSkipsRefusedURL() async {
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { MockWebSocketSession() })
        )
        let store = RelayListStore(pool: pool, policy: .addAndConnect)

        // A non-WebSocket URL is refused by the pool's validation; the resolve
        // must skip it (not throw) and keep the valid relay.
        let available = await store.ensureConnected([
            URL(string: "https://not-a-relay.example.com")!,
            URL(string: "wss://good.example.com")!,
        ])

        #expect(available == [URL(string: "wss://good.example.com")!])
        #expect(await pool.count == 1)
        await pool.disconnectAll()
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
