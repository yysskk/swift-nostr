import Foundation
import NostrCore
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
        let pubkey = "pubkey1"

        await store.store(DirectMessageRelayList(relays: ["wss://a.example.com"]), createdAt: 100, for: pubkey)
        // older → ignored
        await store.store(DirectMessageRelayList(relays: ["wss://b.example.com"]), createdAt: 50, for: pubkey)
        var cached = await store.cachedList(for: pubkey)
        #expect(cached?.relays == ["wss://a.example.com"])

        // newer → wins
        await store.store(DirectMessageRelayList(relays: ["wss://c.example.com"]), createdAt: 200, for: pubkey)
        cached = await store.cachedList(for: pubkey)
        #expect(cached?.relays == ["wss://c.example.com"])
    }

    @Test("Equal createdAt keeps existing entry")
    func equalCreatedAtKeepsExisting() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.store(DirectMessageRelayList(relays: ["wss://a.example.com"]), createdAt: 100, for: pubkey)
        await store.store(DirectMessageRelayList(relays: ["wss://b.example.com"]), createdAt: 100, for: pubkey)

        let cached = await store.cachedList(for: pubkey)
        #expect(cached?.relays == ["wss://a.example.com"])
    }

    @Test("Resolves inbox relay URLs")
    func inboxURLResolution() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.store(
            DirectMessageRelayList(relays: ["wss://inbox.example.com", "wss://dm.example.com"]),
            createdAt: 1,
            for: pubkey
        )

        let inbox = await store.inboxRelayURLs(for: pubkey)
        let expected: Set<URL> = [
            URL(string: "wss://inbox.example.com")!,
            URL(string: "wss://dm.example.com")!,
        ]
        #expect(inbox == expected)
    }

    @Test("Unknown pubkey resolves to an empty inbox set")
    func unknownPubkeyResolvesEmpty() async {
        let store = makeStore()
        let inbox = await store.inboxRelayURLs(for: "nobody")
        #expect(inbox.isEmpty)
    }

    @Test("An empty DM relay list resolves to an empty inbox set")
    func emptyListResolvesEmptyInbox() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.store(DirectMessageRelayList(relays: []), createdAt: 1, for: pubkey)

        // A peer advertising an empty list is "resolved" but routes nowhere, so the
        // caller falls back to the full pool rather than refetching.
        #expect(await store.isResolved(for: pubkey) == true)
        #expect(await store.inboxRelayURLs(for: pubkey).isEmpty)
    }

    // MARK: - Negative cache

    @Test("A fresh pubkey is unresolved until looked up")
    func freshPubkeyIsUnresolved() async {
        let store = makeStore()
        #expect(await store.isResolved(for: "nobody") == false)
    }

    @Test("markNoList resolves a pubkey without caching a list")
    func markNoListResolvesWithoutCaching() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.markNoList(for: pubkey)

        #expect(await store.isResolved(for: pubkey) == true)
        // The negative cache must not leak a phantom list through the read APIs.
        #expect(await store.cachedList(for: pubkey) == nil)
        #expect(await store.inboxRelayURLs(for: pubkey).isEmpty)
    }

    @Test("A cached list counts as resolved")
    func cachedListIsResolved() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.store(DirectMessageRelayList(relays: ["wss://a.example.com"]), createdAt: 1, for: pubkey)
        #expect(await store.isResolved(for: pubkey) == true)
    }

    @Test("Storing a real list clears a prior no-list mark")
    func storingClearsNoListMark() async {
        let store = makeStore()
        let pubkey = "pubkey1"

        await store.markNoList(for: pubkey)
        await store.store(DirectMessageRelayList(relays: ["wss://a.example.com"]), createdAt: 1, for: pubkey)

        #expect(await store.cachedList(for: pubkey)?.relays == ["wss://a.example.com"])
        #expect(await store.isResolved(for: pubkey) == true)
    }

    @Test("Ingest a kind 10050 event")
    func ingestEvent() async throws {
        let store = makeStore()
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let event = try signer.signDirectMessageRelayList(relays: ["wss://inbox.example.com"])
        let ingested = await store.ingest(event)
        #expect(ingested != nil)

        let cached = await store.cachedList(for: keyPair.publicKeyHex)
        #expect(cached?.relays == ["wss://inbox.example.com"])
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
        let urls: Set<URL> = [URL(string: "wss://absent.example.com")!]
        let available = await store.ensureConnected(urls)
        #expect(available.isEmpty)
    }
}

@Suite("Replaceable Cache Tests")
struct ReplaceableCacheTests {

    @Test("Newer value wins")
    func newerWins() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: 100, for: "k")
        cache.store("b", createdAt: 50, for: "k")  // older → ignored
        #expect(cache.value(for: "k") == "a")
        cache.store("c", createdAt: 200, for: "k")  // newer → wins
        #expect(cache.value(for: "k") == "c")
    }

    @Test("Equal createdAt keeps existing value and returns it")
    func equalKeepsExisting() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: 100, for: "k")
        let effective = cache.store("b", createdAt: 100, for: "k")
        #expect(effective == "a")
        #expect(cache.value(for: "k") == "a")
    }

    @Test("Missing key returns nil")
    func missingReturnsNil() {
        let cache = ReplaceableCache<Int>()
        #expect(cache.value(for: "absent") == nil)
    }

    @Test("Keys are independent")
    func keysIndependent() {
        var cache = ReplaceableCache<String>()
        cache.store("a", createdAt: 1, for: "k1")
        cache.store("b", createdAt: 1, for: "k2")
        #expect(cache.value(for: "k1") == "a")
        #expect(cache.value(for: "k2") == "b")
    }
}
