import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrSubscribing`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows what each one
/// forwards — filters, targets, and buffering policy, defaults included — without a relay pool.
@Suite("Subscription Capability Tests")
struct SubscriptionCapabilityTests {
    private let relayA = RelayURL("wss://a.example.com")!
    private let relayB = RelayURL("wss://b.example.com")!

    private func note(_ content: String) throws -> Event {
        try EventSigner(keyPair: try KeyPair()).sign(.textNote(content))
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

    // MARK: - Subscribe primitive's short forms

    @Test("subscribing without targets opens on the whole pool with unbounded buffering")
    func subscribeShortFormBroadcasts() async throws {
        let event = try note("live")
        let stub = RecordingSubscriptionCapabilities(cannedItems: [
            .eose(relayURL: relayA), .event(relayURL: relayA, event: event),
        ])
        let subscriptions: any NostrSubscribing = stub
        let filter = Filter(kinds: [.textNote], limit: 10)

        let subscription = try await subscriptions.subscribe(filters: [filter])

        let recorded = try await onlySubscribe(stub)
        #expect(recorded.filters == [filter])
        #expect(recorded.relayURLs == nil)
        #expect(policy(recorded.bufferingPolicy) == "unbounded")
        // The sequence handed back is the primitive's, unchanged.
        var relays: [RelayURL] = []
        for await item in subscription {
            relays.append(item.relayURL)
        }
        #expect(relays == [relayA, relayA])
    }

    @Test("subscribing without targets forwards a custom buffering policy")
    func subscribeShortFormForwardsBufferingPolicy() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub

        _ = try await subscriptions.subscribe(
            filters: [Filter(kinds: [.textNote])], bufferingPolicy: .bufferingNewest(5))

        let recorded = try await onlySubscribe(stub)
        #expect(recorded.relayURLs == nil)
        #expect(policy(recorded.bufferingPolicy) == "newest(5)")
    }

    @Test("subscribing to chosen relays forwards them, an empty set included")
    func subscribeShortFormTargets() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub
        let filter = Filter(kinds: [.textNote])

        _ = try await subscriptions.subscribe(filters: [filter], to: [relayA, relayB])
        _ = try await subscriptions.subscribe(filters: [filter], to: [relayB], bufferingPolicy: .bufferingOldest(2))
        // An empty set stays a set — it reaches the primitive, which rejects it, rather than
        // collapsing to nil and subscribing on the whole pool.
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            try await subscriptions.subscribe(filters: [filter], to: [])
        }

        let recorded = await stub.subscribes
        #expect(recorded.map(\.relayURLs) == [[relayA, relayB], [relayB], []])
        #expect(recorded.map { policy($0.bufferingPolicy) } == ["unbounded", "oldest(2)", "unbounded"])
    }

    // MARK: - Conveniences

    @Test("events opens on the whole pool with unbounded buffering and yields only event payloads")
    func eventsShortFormBroadcasts() async throws {
        let first = try note("first")
        let second = try note("second")
        let stub = RecordingSubscriptionCapabilities(cannedItems: [
            .event(relayURL: relayA, event: first),
            .notice(relayURL: relayA, message: "hello"),
            .eose(relayURL: relayA),
            .event(relayURL: relayB, event: second),
        ])
        let subscriptions: any NostrSubscribing = stub
        let filter = Filter(kinds: [.textNote])

        let events = try await subscriptions.events(filters: [filter])

        let recorded = try await onlySubscribe(stub)
        #expect(recorded.filters == [filter])
        #expect(recorded.relayURLs == nil)
        #expect(policy(recorded.bufferingPolicy) == "unbounded")
        var received: [Event] = []
        for await event in events {
            received.append(event)
        }
        #expect(received == [first, second])
    }

    @Test("events on chosen relays forwards the relays and buffering policy")
    func eventsShortFormTargets() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub

        _ = try await subscriptions.events(filters: [Filter(kinds: [.textNote])], to: [relayB])
        _ = try await subscriptions.events(filters: [Filter(kinds: [.textNote])], bufferingPolicy: .bufferingNewest(1))
        _ = try await subscriptions.events(
            filters: [Filter(kinds: [.textNote])], to: [relayA], bufferingPolicy: .bufferingNewest(3))

        let recorded = await stub.subscribes
        #expect(recorded.map(\.relayURLs) == [[relayB], nil, [relayA]])
        #expect(recorded.map { policy($0.bufferingPolicy) } == ["unbounded", "newest(1)", "newest(3)"])
    }

    @Test("userTimeline follows the user's notes on the whole pool, 100 stored by default")
    func userTimeline() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub
        let user = PublicKey.fixture("user")

        _ = try await subscriptions.userTimeline(publicKey: user)
        _ = try await subscriptions.userTimeline(publicKey: user, limit: 7)

        let recorded = await stub.subscribes
        #expect(
            recorded.map(\.filters) == [
                [.userNotes(publicKey: user, limit: 100)], [.userNotes(publicKey: user, limit: 7)],
            ])
        #expect(
            recorded.map(\.filters) == [
                [Filter(authors: [user], kinds: [.textNote], limit: 100)],
                [Filter(authors: [user], kinds: [.textNote], limit: 7)],
            ])
        #expect(recorded.allSatisfy { $0.relayURLs == nil && policy($0.bufferingPolicy) == "unbounded" })
    }

    @Test("globalFeed follows every text note on the whole pool, 100 stored by default")
    func globalFeed() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub

        _ = try await subscriptions.globalFeed()
        _ = try await subscriptions.globalFeed(limit: 20)

        let recorded = await stub.subscribes
        #expect(
            recorded.map(\.filters) == [
                [Filter(kinds: [.textNote], limit: 100)], [Filter(kinds: [.textNote], limit: 20)],
            ])
        #expect(recorded.allSatisfy { $0.relayURLs == nil && policy($0.bufferingPolicy) == "unbounded" })
    }

    @Test("mentions follows notes tagging the user on the whole pool, 100 stored by default")
    func mentions() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub
        let user = PublicKey.fixture("user")

        _ = try await subscriptions.mentions(publicKey: user)
        _ = try await subscriptions.mentions(publicKey: user, limit: 3)

        let recorded = await stub.subscribes
        #expect(
            recorded.map(\.filters) == [
                [Filter(kinds: [.textNote], publicKeyReferences: [user], limit: 100)],
                [Filter(kinds: [.textNote], publicKeyReferences: [user], limit: 3)],
            ])
        #expect(recorded.allSatisfy { $0.relayURLs == nil && policy($0.bufferingPolicy) == "unbounded" })
    }

    @Test("metadata follows the profiles of every given key on the whole pool, without a limit")
    func metadata() async throws {
        let stub = RecordingSubscriptionCapabilities()
        let subscriptions: any NostrSubscribing = stub
        let keys = [PublicKey.fixture("alice"), PublicKey.fixture("bob")]

        _ = try await subscriptions.metadata(publicKeys: keys)

        let recorded = try await onlySubscribe(stub)
        #expect(recorded.filters == [Filter(authors: keys, kinds: [.setMetadata])])
        #expect(recorded.relayURLs == nil)
        #expect(policy(recorded.bufferingPolicy) == "unbounded")
    }
}
