import Foundation
import NostrClient
import NostrCore
import NostrTestSupport
import Testing

/// Counts the calls to `close()` per subscription id.
private actor CloseCounter {
    private(set) var value: [SubscriptionID: Int] = [:]

    func record(_ id: SubscriptionID) {
        value[id, default: 0] += 1
    }
}

@Suite("Relay Subscription Tests")
struct RelaySubscriptionTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    /// A finished subscription with `id` that records its calls to `close()` in `closeCount`.
    private func makeSubscription(
        id: SubscriptionID,
        items: [SubscriptionEvent] = [],
        closeCount: CloseCounter
    ) -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        for item in items {
            continuation.yield(item)
        }
        continuation.finish()
        return SubscriptionSequence(
            id: id,
            expectedRelays: [relayURL],
            stream: stream,
            onClose: { await closeCount.record(id) }
        )
    }

    private func makeParser() -> DirectMessageParser {
        DirectMessageParser(signer: EventSigner(keyPair: KeyPair()))
    }

    @Test("every view of a subscription reports the subscription's id and relays")
    func viewsForwardIDAndRelays() {
        let closeCount = CloseCounter()
        let base = makeSubscription(id: "sub_dm", closeCount: closeCount)
        let payloads = DirectMessagePayloadSequence(subscription: base, parser: makeParser())
        let subscriptions: [any RelaySubscription] = [base, base.events, payloads, payloads.messages]

        for subscription in subscriptions {
            #expect(subscription.id == "sub_dm")
            #expect(subscription.expectedRelays == [relayURL])
        }
    }

    @Test("closing through any view closes the underlying subscription")
    func closeThroughAnyViewClosesBase() async {
        let closeCount = CloseCounter()
        let base = makeSubscription(id: "sub_dm", closeCount: closeCount)
        let payloads = DirectMessagePayloadSequence(subscription: base, parser: makeParser())
        let subscriptions: [any RelaySubscription] = [base, base.events, payloads, payloads.messages]

        for subscription in subscriptions {
            await subscription.close()
        }

        #expect(await closeCount.value == ["sub_dm": 4])
    }

    @Test("subscriptions of different element types close together")
    func heterogeneousSubscriptionsCloseTogether() async {
        let closeCount = CloseCounter()
        let feed = makeSubscription(id: "sub_feed", closeCount: closeCount)
        let notes = makeSubscription(id: "sub_notes", closeCount: closeCount).events
        let inbox = DirectMessagePayloadSequence(
            subscription: makeSubscription(id: "sub_inbox", closeCount: closeCount),
            parser: makeParser()
        )
        let subscriptions: [any RelaySubscription] = [feed, notes, inbox]

        await closeAll(subscriptions)

        #expect(await closeCount.value == ["sub_feed": 1, "sub_notes": 1, "sub_inbox": 1])
    }

    @Test("a generic function iterates any conforming sequence")
    func genericIterationOverConformer() async throws {
        let closeCount = CloseCounter()
        let event = EventSigner(keyPair: KeyPair()).sign(.textNote("hello"))
        let subscription = makeSubscription(
            id: "sub_feed",
            items: [.eose(relayURL: relayURL), .event(relayURL: relayURL, event: event)],
            closeCount: closeCount
        )

        let first = try await firstElement(of: subscription.events)

        #expect(first == event)
    }

    private func closeAll(_ subscriptions: [any RelaySubscription]) async {
        for subscription in subscriptions {
            await subscription.close()
        }
    }

    private func firstElement<S: RelaySubscription>(of subscription: S) async throws -> S.Element? {
        var iterator = subscription.makeAsyncIterator()
        return try await iterator.next()
    }
}
