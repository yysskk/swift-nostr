import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Relay Pool Deduplication Tests")
struct RelayPoolDeduplicationTests {

    private let urlA = URL(string: "wss://a.example.com")!
    private let urlB = URL(string: "wss://b.example.com")!

    // MARK: - Fixtures

    /// A relay config that fails fast and never reconnects, keeping tests deterministic.
    private var noReconnectConfig: RelayConnectionConfig {
        RelayConnectionConfig(connectionTimeout: 1, pingInterval: 60, autoReconnect: false)
    }

    /// A pool holding one connected relay per URL, paired with the socket driving it.
    /// Relays connect one at a time so each pairs with a known socket.
    private func makeConnectedPool(
        relayURLs: [URL],
        maxDeduplicationCacheSize: Int = 10000,
        deduplicationCacheTTL: TimeInterval = 300
    ) async throws -> (pool: RelayPool, sockets: [MockWebSocketSession]) {
        let sockets = relayURLs.map { _ in MockWebSocketSession() }
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: noReconnectConfig,
                maxDeduplicationCacheSize: maxDeduplicationCacheSize,
                deduplicationCacheTTL: deduplicationCacheTTL
            ),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets[counter.next()] })
        )
        for url in relayURLs {
            try await pool.addRelay(url).connect()
        }
        return (pool, sockets)
    }

    private func makeEvent(content: String) throws -> Event {
        try EventSigner(keyPair: try KeyPair()).signTextNote(content: content)
    }

    /// A canned `["EVENT", subscriptionId, {...}]` relay frame for `event`.
    private func eventFrame(subscriptionId: String, event: Event) throws -> String {
        let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
        return "[\"EVENT\",\"\(subscriptionId)\",\(json)]"
    }

    /// Subscribes `subscriptionId` on the whole pool and returns the events it delivers.
    /// Waits for every socket's REQ so later frames cannot race the listeners.
    private func subscribe(
        _ pool: RelayPool,
        subscriptionId: String,
        sockets: [MockWebSocketSession]
    ) async throws -> EventCollector {
        let collector = EventCollector()
        try await pool.subscribe(subscriptionId: subscriptionId, filters: [Filter()]) { message in
            collector.record(message)
        }
        for socket in sockets {
            try await NIP42TestSupport.pollUntil {
                socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") }
            }
        }
        return collector
    }

    // MARK: - Per-subscription scope

    @Test("an event matching two subscriptions is delivered to both")
    func eventMatchingTwoSubscriptionsReachesBoth() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA])
        let socket = sockets[0]
        let first = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        let second = try await subscribe(pool, subscriptionId: "sub_2", sockets: sockets)

        // One relay answering both REQs with the same event.
        let event = try makeEvent(content: "matches both filters")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_2", event: event)))

        try await NIP42TestSupport.pollUntil { first.recorded == [event] }
        try await NIP42TestSupport.pollUntil { second.recorded == [event] }
        #expect(await pool.deduplicationCacheSize == 2)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_1") == 1)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_2") == 1)

        await pool.disconnectAll()
    }

    @Test("copies of one event from two relays collapse into a single delivery")
    func duplicateCopiesAcrossRelaysCollapse() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA, urlB])
        let collector = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)

        let event = try makeEvent(content: "stored on both relays")
        sockets[0].deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        try await NIP42TestSupport.pollUntil { collector.recorded == [event] }

        // The second relay's copy, followed by a distinct event on the same socket: frames
        // arrive in order, so seeing the sentinel proves the duplicate was already handled.
        let sentinel = try makeEvent(content: "sentinel")
        sockets[1].deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        sockets[1].deliver(.string(try eventFrame(subscriptionId: "sub_1", event: sentinel)))

        try await NIP42TestSupport.pollUntil { collector.recorded.count == 2 }
        #expect(collector.recorded == [event, sentinel])
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_1") == 2)

        await pool.disconnectAll()
    }

    // MARK: - Cache lifetime

    @Test("unsubscribe discards only that subscription's cache")
    func unsubscribeDiscardsOwnCacheOnly() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA])
        let socket = sockets[0]
        let first = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        let second = try await subscribe(pool, subscriptionId: "sub_2", sockets: sockets)

        let event = try makeEvent(content: "seen by both subscriptions")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_2", event: event)))
        try await NIP42TestSupport.pollUntil { first.recorded == [event] }
        try await NIP42TestSupport.pollUntil { second.recorded == [event] }

        await pool.unsubscribe(subscriptionId: "sub_1")
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_1") == 0)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_2") == 1)
        #expect(await pool.deduplicationCacheSize == 1)

        await pool.disconnectAll()
    }

    @Test("a subscription reusing an unsubscribed ID receives the event again")
    func resubscribingWithTheSameIDStartsFromAnEmptyCache() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA])
        let socket = sockets[0]
        let event = try makeEvent(content: "delivered to both subscriptions in turn")

        let first = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        try await NIP42TestSupport.pollUntil { first.recorded == [event] }
        await pool.unsubscribe(subscriptionId: "sub_1")

        let second = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        try await NIP42TestSupport.pollUntil { second.recorded == [event] }

        await pool.disconnectAll()
    }

    @Test("the TTL sweep expires entries and drops emptied subscriptions")
    func sweepExpiresEntriesPastTheTTL() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA], deduplicationCacheTTL: 300)
        let socket = sockets[0]
        let collector = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)

        let event = try makeEvent(content: "cached until the TTL passes")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        try await NIP42TestSupport.pollUntil { collector.recorded == [event] }

        // A sweep inside the TTL keeps the entry; one past it clears the subscription.
        await pool.expireCachedEvents(now: Date().addingTimeInterval(299))
        #expect(await pool.deduplicationCacheSize == 1)
        await pool.expireCachedEvents(now: Date().addingTimeInterval(301))
        #expect(await pool.deduplicationCacheSize == 0)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_1") == 0)

        await pool.disconnectAll()
    }

    @Test("the size limit holds as events arrive, without waiting for a sweep")
    func sizeLimitHoldsAsEventsArrive() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA], maxDeduplicationCacheSize: 1)
        let socket = sockets[0]
        let first = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        let second = try await subscribe(pool, subscriptionId: "sub_2", sockets: sockets)

        // One event per subscription, delivered in a known order. No sweep runs in between:
        // the cache is trimmed as each event is recorded.
        let older = try makeEvent(content: "recorded first")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: older)))
        try await NIP42TestSupport.pollUntil { first.recorded == [older] }
        let newer = try makeEvent(content: "recorded second")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_2", event: newer)))
        try await NIP42TestSupport.pollUntil { second.recorded == [newer] }

        #expect(await pool.deduplicationCacheSize == 1)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_1") == 0)
        #expect(await pool.deduplicationCacheSize(forSubscription: "sub_2") == 1)

        await pool.disconnectAll()
    }

    @Test("clearDeduplicationCache empties every subscription's cache")
    func clearEmptiesEveryCache() async throws {
        let (pool, sockets) = try await makeConnectedPool(relayURLs: [urlA])
        let socket = sockets[0]
        let first = try await subscribe(pool, subscriptionId: "sub_1", sockets: sockets)
        let second = try await subscribe(pool, subscriptionId: "sub_2", sockets: sockets)

        let event = try makeEvent(content: "cached under two subscriptions")
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_1", event: event)))
        socket.deliver(.string(try eventFrame(subscriptionId: "sub_2", event: event)))
        try await NIP42TestSupport.pollUntil { first.recorded == [event] }
        try await NIP42TestSupport.pollUntil { second.recorded == [event] }

        await pool.clearDeduplicationCache()
        #expect(await pool.deduplicationCacheSize == 0)

        await pool.disconnectAll()
    }
}

/// Collects the events a pool subscription delivers, from whichever task delivers them.
private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ message: RelayMessage) {
        guard case .event(_, let event) = message else { return }
        lock.withLock { events.append(event) }
    }

    var recorded: [Event] {
        lock.withLock { events }
    }
}

/// Hands out socket indices in connection order.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.withLock {
            index += 1
            return index
        }
    }
}
