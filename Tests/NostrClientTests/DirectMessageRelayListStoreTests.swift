import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Direct Message Relay List Store Tests (NIP-17, kind 10050)")
struct DirectMessageRelayListStoreTests {

    private func makeStore(policy: GossipRelayPolicy = .requirePresent) -> DirectMessageRelayListStore {
        DirectMessageRelayListStore(pool: RelayPool(), policy: policy)
    }

    @Test("Newer DM relay list wins (replaceable event)")
    func newerWins() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!]), createdAt: Timestamp(rawValue: 100),
            for: publicKey)
        // older → ignored
        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://b.example.com")!]), createdAt: Timestamp(rawValue: 50),
            for: publicKey)
        var cached = await store.cachedList(for: publicKey)
        #expect(cached?.relays == [RelayURL("wss://a.example.com")!])

        // newer → wins
        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://c.example.com")!]), createdAt: Timestamp(rawValue: 200),
            for: publicKey)
        cached = await store.cachedList(for: publicKey)
        #expect(cached?.relays == [RelayURL("wss://c.example.com")!])
    }

    @Test("Equal createdAt keeps existing entry")
    func equalCreatedAtKeepsExisting() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!]), createdAt: Timestamp(rawValue: 100),
            for: publicKey)
        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://b.example.com")!]), createdAt: Timestamp(rawValue: 100),
            for: publicKey)

        let cached = await store.cachedList(for: publicKey)
        #expect(cached?.relays == [RelayURL("wss://a.example.com")!])
    }

    @Test("Resolves inbox relay URLs")
    func inboxURLResolution() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://inbox.example.com")!, RelayURL("wss://dm.example.com")!]),
            createdAt: Timestamp(rawValue: 1),
            for: publicKey
        )

        let inbox = await store.inboxRelayURLs(for: publicKey)
        let expected: Set<RelayURL> = [
            RelayURL("wss://inbox.example.com")!,
            RelayURL("wss://dm.example.com")!,
        ]
        #expect(inbox == expected)
    }

    @Test("Unknown public key resolves to an empty inbox set")
    func unknownPublicKeyResolvesEmpty() async {
        let store = makeStore()
        let inbox = await store.inboxRelayURLs(for: PublicKey.fixture("nobody"))
        #expect(inbox.isEmpty)
    }

    @Test("An empty DM relay list resolves to an empty inbox set")
    func emptyListResolvesEmptyInbox() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(DirectMessageRelayList(relays: []), createdAt: Timestamp(rawValue: 1), for: publicKey)

        // A peer advertising an empty list is "resolved" but routes nowhere, so the
        // caller falls back to the full pool rather than refetching.
        #expect(await store.isResolved(for: publicKey) == true)
        #expect(await store.inboxRelayURLs(for: publicKey).isEmpty)
    }

    // MARK: - Negative cache

    @Test("A fresh public key is unresolved until looked up")
    func freshPublicKeyIsUnresolved() async {
        let store = makeStore()
        #expect(await store.isResolved(for: PublicKey.fixture("nobody")) == false)
    }

    @Test("markNoList resolves a public key without caching a list")
    func markNoListResolvesWithoutCaching() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.markNoList(for: publicKey)

        #expect(await store.isResolved(for: publicKey) == true)
        // The negative cache must not leak a phantom list through the read APIs.
        #expect(await store.cachedList(for: publicKey) == nil)
        #expect(await store.inboxRelayURLs(for: publicKey).isEmpty)
    }

    @Test("A cached list counts as resolved")
    func cachedListIsResolved() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!]), createdAt: Timestamp(rawValue: 1),
            for: publicKey)
        #expect(await store.isResolved(for: publicKey) == true)
    }

    @Test("Storing a real list clears a prior no-list mark")
    func storingClearsNoListMark() async {
        let store = makeStore()
        let publicKey = PublicKey.fixture("publicKey1")

        await store.markNoList(for: publicKey)
        await store.store(
            DirectMessageRelayList(relays: [RelayURL("wss://a.example.com")!]), createdAt: Timestamp(rawValue: 1),
            for: publicKey)

        #expect(await store.cachedList(for: publicKey)?.relays == [RelayURL("wss://a.example.com")!])
        #expect(await store.isResolved(for: publicKey) == true)
    }

    @Test("Ingest a kind 10050 event")
    func ingestEvent() async throws {
        let store = makeStore()
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signDirectMessageRelayList(relays: [RelayURL("wss://inbox.example.com")!])
        let ingested = await store.ingest(event)
        #expect(ingested != nil)

        let cached = await store.cachedList(for: keyPair.publicKey)
        #expect(cached?.relays == [RelayURL("wss://inbox.example.com")!])
    }

    @Test("Ingest ignores a non-10050 event")
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
        let urls: Set<RelayURL> = [RelayURL("wss://absent.example.com")!]
        let available = await store.ensureConnected(urls)
        #expect(available.isEmpty)
    }
}

@Suite("Replaceable Cache Tests")
struct ReplaceableCacheTests {

    @Test("Newer value wins")
    func newerWins() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: Timestamp(rawValue: 100), for: .fixture("k"))
        cache.store("b", createdAt: Timestamp(rawValue: 50), for: .fixture("k"))  // older → ignored
        #expect(cache.value(for: .fixture("k")) == "a")
        cache.store("c", createdAt: Timestamp(rawValue: 200), for: .fixture("k"))  // newer → wins
        #expect(cache.value(for: .fixture("k")) == "c")
    }

    @Test("Equal createdAt keeps existing value and returns it")
    func equalKeepsExisting() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: Timestamp(rawValue: 100), for: .fixture("k"))
        let effective = cache.store("b", createdAt: Timestamp(rawValue: 100), for: .fixture("k"))
        #expect(effective == "a")
        #expect(cache.value(for: .fixture("k")) == "a")
    }

    @Test("Missing key returns nil")
    func missingReturnsNil() {
        let cache = ReplaceableCache<Int>()
        #expect(cache.value(for: .fixture("absent")) == nil)
    }

    @Test("Keys are independent")
    func keysIndependent() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: Timestamp(rawValue: 1), for: .fixture("k1"))
        cache.store("b", createdAt: Timestamp(rawValue: 1), for: .fixture("k2"))
        #expect(cache.value(for: .fixture("k1")) == "a")
        #expect(cache.value(for: .fixture("k2")) == "b")
    }
}
