import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// Disconnecting drops the pool's listener tasks, and nothing recreates them, so a subscription
/// cannot outlive the connections that feed it. The client-facing sequence has to end with them:
/// left open, a `for await` over one waits on events that can never arrive.
@Suite("Subscription Teardown Tests")
struct SubscriptionTeardownTests {

    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        try await ConnectedClientFixture.make()
    }

    /// The hang: `relays.disconnect()` cancelled the pool's listeners but left the client's
    /// continuation open, so the caller's loop never ended and never received anything again.
    @Test("disconnecting ends an open subscription sequence")
    func disconnectEndsSubscriptionSequence() async throws {
        let (client, _) = try await makeClient()
        let subscription = try await client.subscriptions.subscribe(filters: [Filter(kinds: [1])])

        let drained = Task {
            var count = 0
            for await _ in subscription { count += 1 }
            return count
        }

        await client.relays.disconnect()

        // Ends rather than hanging; the value itself is incidental.
        _ = await drained.value
    }

    @Test("disconnecting clears the pool's subscription bookkeeping")
    func disconnectClearsPoolState() async throws {
        let (client, _) = try await makeClient()
        // Held, as a caller iterating it would: releasing the sequence closes the subscription.
        let subscription = try await client.subscriptions.subscribe(filters: [Filter(kinds: [1])])

        #expect(await client.pool.subscriptionHandlerCount == 1)
        #expect(await client.activeSubscriptionCount == 1)

        await client.relays.disconnect()
        withExtendedLifetime(subscription) {}

        // Retained, these grew on every connect/disconnect cycle while naming subscriptions the
        // pool could no longer serve.
        #expect(await client.pool.subscriptionHandlerCount == 0)
        #expect(await client.activeSubscriptionCount == 0)
    }

    /// Cancelling a listener does not stop a frame already in flight, and the handler is resolved
    /// at delivery time — so a straggler from the previous generation was handed to the *new*
    /// handler, delivering every control message twice.
    @Test("re-subscribing under an id in use does not double-deliver")
    func resubscribingDoesNotDoubleDeliver() async throws {
        let (client, socket) = try await makeClient()
        let pool = await client.pool

        let counts = MessageCounts()
        for _ in 0..<3 {
            _ = try await pool.subscribe(
                subscriptionId: "sub", filters: [Filter(kinds: [1])]
            ) { message in
                if case .endOfStoredEvents = message { counts.bump() }
            }
        }

        socket.deliver(.string(#"["EOSE","sub"]"#))
        try await pollUntil { counts.value >= 1 }
        try await Task.sleep(for: .milliseconds(50))

        #expect(counts.value == 1)
        await client.relays.disconnect()
    }

    /// A fresh REQ makes the relay resend its stored events. The dedup cache is scoped to the
    /// subscription id, not the generation, so anything the previous generation had already seen
    /// would be discarded before the new handler — which never received it — could.
    @Test("re-subscribing under an id in use still receives the relay's stored events")
    func resubscribingReceivesStoredEvents() async throws {
        let (client, socket) = try await makeClient()
        let pool = await client.pool

        let signer = EventSigner(keyPair: try KeyPair())
        let stored = try signer.signTextNote(content: "stored")
        let storedJSON = String(decoding: try JSONEncoder().encode(stored), as: UTF8.self)

        let firstSeen = MessageCounts()
        _ = try await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { message in
            if case .event = message { firstSeen.bump() }
        }
        socket.deliver(.string("[\"EVENT\",\"sub\",\(storedJSON)]"))
        try await pollUntil { firstSeen.value == 1 }

        // Re-subscribe under the same id; the relay resends the same stored event.
        let secondSeen = MessageCounts()
        _ = try await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { message in
            if case .event = message { secondSeen.bump() }
        }
        socket.deliver(.string("[\"EVENT\",\"sub\",\(storedJSON)]"))
        try await pollUntil { secondSeen.value == 1 }

        #expect(secondSeen.value == 1)
        await client.relays.disconnect()
    }

    /// The listener has to be registered on the connection before the REQ goes out, or the events
    /// and the EOSE that answer it are dropped — and a fetch then waits out its whole timeout.
    @Test("a subscription receives an EOSE that follows its REQ immediately")
    func subscriptionReceivesImmediateEOSE() async throws {
        let (client, socket) = try await makeClient()
        let pool = await client.pool

        let counts = MessageCounts()
        _ = try await pool.subscribe(
            subscriptionId: "sub", filters: [Filter(kinds: [1])]
        ) { message in
            if case .endOfStoredEvents = message { counts.bump() }
        }

        socket.deliver(.string(#"["EOSE","sub"]"#))
        try await pollUntil { counts.value == 1 }

        await client.relays.disconnect()
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }
}

/// Counts handler invocations across the listener tasks.
private final class MessageCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func bump() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// The generation token guards two distinct races, and both are subtle enough to deserve their own
/// coverage: a number reused after an unsubscribe, and two subscribes on one id overlapping across
/// the suspension that registers their message streams.
@Suite("Subscription Generation Tests")
struct SubscriptionGenerationTests {

    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        try await ConnectedClientFixture.make()
    }

    /// Counting per id from zero and dropping the entry on unsubscribe issued generation 1 twice,
    /// so a straggler from the first set matched the second and delivered into it.
    @Test("a reused subscription id never reuses its generation")
    func reusedIdGetsAFreshGeneration() async throws {
        let (client, _) = try await makeClient()
        let pool = await client.pool

        _ = try await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { _ in }
        let first = await pool.subscriptionGeneration(for: "sub")

        await pool.unsubscribe(subscriptionId: "sub")
        #expect(await pool.subscriptionGeneration(for: "sub") == nil)

        _ = try await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { _ in }
        let second = await pool.subscriptionGeneration(for: "sub")

        #expect(first != nil)
        #expect(second != nil)
        #expect(first != second)

        await client.relays.disconnect()
    }

    /// Distinct ids draw from the same counter, so no two live subscriptions share a generation.
    @Test("generations are unique across subscriptions")
    func generationsAreUniqueAcrossSubscriptions() async throws {
        let (client, _) = try await makeClient()
        let pool = await client.pool

        _ = try await pool.subscribe(subscriptionId: "a", filters: [Filter(kinds: [1])]) { _ in }
        _ = try await pool.subscribe(subscriptionId: "b", filters: [Filter(kinds: [1])]) { _ in }

        let a = await pool.subscriptionGeneration(for: "a")
        let b = await pool.subscriptionGeneration(for: "b")
        #expect(a != b)

        await client.relays.disconnect()
    }

    /// Registering the message stream suspends, so two subscribes on one id can interleave. Each
    /// used to find nothing to cancel and then overwrite the other's entry, stranding a set of
    /// listeners that nothing could cancel and that held a stream open on the connection.
    @Test("overlapping subscribes on one id leave a single set of listeners")
    func overlappingSubscribesLeaveOneListenerSet() async throws {
        let (client, socket) = try await makeClient()
        let pool = await client.pool

        let deliveries = MessageCounts()
        async let first: Void = {
            _ = try? await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { message in
                if case .endOfStoredEvents = message { deliveries.bump() }
            }
        }()
        async let second: Void = {
            _ = try? await pool.subscribe(subscriptionId: "sub", filters: [Filter(kinds: [1])]) { message in
                if case .endOfStoredEvents = message { deliveries.bump() }
            }
        }()
        _ = await (first, second)

        // One winner holds the id: a single generation and one set of listener tasks.
        #expect(await pool.subscriptionGeneration(for: "sub") != nil)
        #expect(await pool.listenerTaskCount(for: "sub") == 1)

        // And a stranded set from the loser would deliver alongside it.
        socket.deliver(.string(#"["EOSE","sub"]"#))
        try await pollUntil { deliveries.value >= 1 }
        try await Task.sleep(for: .milliseconds(80))
        #expect(deliveries.value == 1)

        await client.relays.disconnect()
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }
}
