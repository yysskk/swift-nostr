import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrSubscribing`` short forms are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows what each one
/// forwards — filters, route, and buffering policy, defaults included — without a relay pool.
@Suite("Subscription Capability Tests")
struct SubscriptionCapabilityTests {
    private let relayA = RelayURL("wss://a.example.com")!
    private let relayB = RelayURL("wss://b.example.com")!

    private func note(_ content: String) throws -> Event {
        EventSigner(keyPair: KeyPair()).sign(.textNote(content))
    }

    /// The one subscribe the stub recorded.
    private func onlySubscribe(
        _ stub: RecordingSubscriptionCapabilities
    ) async throws -> RecordingSubscriptionCapabilities.Subscribe {
        let subscribes = await stub.subscribes
        #expect(subscribes.count == 1)
        return try #require(subscribes.first)
    }

    /// A comparable spelling of a buffering policy, which is not `Equatable`.
    private func policy(_ policy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy) -> String {
        if case .unbounded = policy { return "unbounded" }
        if case .bufferingNewest(let limit) = policy { return "newest(\(limit))" }
        if case .bufferingOldest(let limit) = policy { return "oldest(\(limit))" }
        return "unknown"
    }

    // MARK: - Subscribe primitive's short form

    @Test("subscribing without a route opens on the whole pool with unbounded buffering")
    func subscribeShortFormDefaultsToPool() async throws {
        let event = try note("live")
        let stub = RecordingSubscriptionCapabilities(cannedItems: [
            .eose(relayURL: relayA), .event(relayURL: relayA, event: event),
        ])
        let subscriptions: any NostrSubscribing = stub
        let filter = Filter(kinds: [.textNote], limit: 10)

        let subscription = try await subscriptions.subscribe(filters: [filter])

        let recorded = try await onlySubscribe(stub)
        #expect(recorded.filters == [filter])
        #expect(recorded.route == .pool)
        #expect(policy(recorded.bufferingPolicy) == "unbounded")
        // The sequence handed back is the primitive's, unchanged.
        var relays: [RelayURL] = []
        for await item in subscription {
            relays.append(item.relayURL)
        }
        #expect(relays == [relayA, relayA])
    }

    @Test("subscribing along a route forwards it with unbounded buffering, an empty relay set included")
    func subscribeShortFormForwardsRoute() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub
        let filter = Filter(authors: [PublicKey.fixture("author")], kinds: [.textNote])

        _ = try await subscriptions.subscribe(filters: [filter], route: .relays([relayA, relayB]))
        _ = try await subscriptions.subscribe(filters: [filter], route: .outbox)
        // An empty set stays a `.relays` route — it reaches the primitive, which rejects it, rather
        // than collapsing to the whole pool.
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            try await subscriptions.subscribe(filters: [filter], route: .relays([]))
        }

        let recorded = await stub.subscribes
        #expect(recorded.map(\.route) == [.relays([relayA, relayB]), .outbox, .relays([])])
        #expect(recorded.allSatisfy { policy($0.bufferingPolicy) == "unbounded" })
    }
}
