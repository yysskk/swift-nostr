import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Subscription Sequence Tests")
struct SubscriptionSequenceTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

    private func makeEvent(content: String) throws -> Event {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)
        return signer.sign(.textNote(content))
    }

    private func makeSequence(
        items: [SubscriptionEvent]
    ) -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        for item in items {
            continuation.yield(item)
        }
        continuation.finish()
        return SubscriptionSequence(
            id: "sub_test",
            expectedRelays: [relayURL],
            stream: stream,
            onClose: {}
        )
    }

    /// A client backed by one connected mock relay, so subscriptions have a live target.
    private func makeConnectedClient(
        gossipPolicy: GossipRelayPolicy = .addAndConnect
    ) async throws -> (NostrClient, MockWebSocketSession) {
        let made = try await ConnectedClientFixture.make(relayURL: relayURL, gossipPolicy: gossipPolicy)
        return (made.client, made.socket)
    }

    @Test("sequence yields all subscription events in order")
    func sequenceYieldsAllItemsInOrder() async throws {
        let event = try makeEvent(content: "hello")
        let sequence = makeSequence(items: [
            .event(relayURL: relayURL, event: event),
            .eose(relayURL: relayURL),
            .notice(relayURL: relayURL, message: "note"),
        ])

        var received: [SubscriptionEvent] = []
        for await item in sequence {
            received.append(item)
        }

        #expect(received.count == 3)
        guard case .event(_, let first) = received[0] else {
            Issue.record("expected .event first")
            return
        }
        #expect(first == event)
        guard case .eose = received[1] else {
            Issue.record("expected .eose second")
            return
        }
    }

    @Test("events view yields only event payloads")
    func eventsViewFiltersNonEventItems() async throws {
        let eventA = try makeEvent(content: "a")
        let eventB = try makeEvent(content: "b")
        let sequence = makeSequence(items: [
            .notice(relayURL: relayURL, message: "before"),
            .event(relayURL: relayURL, event: eventA),
            .eose(relayURL: relayURL),
            .event(relayURL: relayURL, event: eventB),
            .closed(relayURL: relayURL, message: "bye"),
        ])

        var received: [Event] = []
        for await event in sequence.events {
            received.append(event)
        }

        #expect(received == [eventA, eventB])
    }

    @Test("events view exposes id, expectedRelays, and close")
    func eventsViewExposesMetadata() {
        let sequence = makeSequence(items: [])
        #expect(sequence.events.id == "sub_test")
        #expect(sequence.events.expectedRelays == [relayURL])
    }

    @Test("subscribe on an empty pool throws emptyPool")
    func subscribeOnEmptyPoolThrows() async throws {
        let client = NostrClient()

        await #expect(throws: RelayPool.Error.emptyPool) {
            _ = try await client.subscriptions.subscribe(filters: [Filter()])
        }
        #expect(await client.activeSubscriptionCount == 0)
    }

    @Test("subscribe reaches the pooled relay via an alternate target spelling")
    func subscribeViaAlternateSpelling() async throws {
        let (client, socket) = try await makeConnectedClient()

        let subscription = try await client.subscriptions.subscribe(
            filters: [Filter()], route: .relays([RelayURL("WSS://Relay.Example.COM/")!]))
        try await NIP42TestSupport.pollUntil {
            socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") }
        }
        #expect(subscription.expectedRelays == [relayURL])

        await subscription.close()
        await client.relays.disconnect()
    }

    @Test("close ends iteration and is idempotent")
    func closeEndsIterationAndIsIdempotent() async throws {
        let (client, _) = try await makeConnectedClient()
        let subscription = try await client.subscriptions.subscribe(filters: [Filter()])

        let consumer = Task {
            var count = 0
            for await _ in subscription {
                count += 1
            }
            return count
        }

        // Give the consumer a moment to start iterating, then close twice.
        try await Task.sleep(for: .milliseconds(50))
        await subscription.close()
        await subscription.close()

        let consumed = await consumer.value
        #expect(consumed == 0)
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("cancelling the consuming task tears down the subscription")
    func taskCancellationTearsDownSubscription() async throws {
        let (client, _) = try await makeConnectedClient()
        let subscription = try await client.subscriptions.subscribe(filters: [Filter()])
        #expect(await client.activeSubscriptionCount == 1)

        let consumer = Task {
            for await _ in subscription {}
        }

        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        await consumer.value

        // onTermination unsubscribes asynchronously; poll briefly.
        for _ in 0..<50 {
            if await client.activeSubscriptionCount == 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("unsubscribe(id:) finishes the stream")
    func unsubscribeFinishesStream() async throws {
        let (client, _) = try await makeConnectedClient()
        let subscription = try await client.subscriptions.subscribe(filters: [Filter()])

        let consumer = Task {
            for await _ in subscription {}
            return true
        }

        try await Task.sleep(for: .milliseconds(50))
        await client.subscriptions.unsubscribe(id: subscription.id)

        let finished = await consumer.value
        #expect(finished)
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("subscriptions.unsubscribeAll finishes every stream")
    func unsubscribeAllFinishesStreams() async throws {
        let (client, _) = try await makeConnectedClient()
        let first = try await client.subscriptions.subscribe(filters: [Filter()])
        let second = try await client.subscriptions.subscribe(filters: [Filter()])
        #expect(await client.activeSubscriptionCount == 2)

        let consumers = [first, second].map { subscription in
            Task {
                for await _ in subscription {}
                return true
            }
        }

        try await Task.sleep(for: .milliseconds(50))
        await client.subscriptions.unsubscribeAll()

        for consumer in consumers {
            #expect(await consumer.value)
        }
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("a Filter preset reaches the relay unchanged through subscribe(filters:)")
    func filterPresetRequest() async throws {
        let (client, socket) = try await makeConnectedClient()

        let feed = try await client.subscriptions.subscribe(filters: [.globalFeed(limit: 50)])
        try await NIP42TestSupport.pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        let frame = try #require(socket.sentTextFrames.first { $0.hasPrefix("[\"REQ\"") })
        let request = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [Any])
        let filter = try #require(request.last as? [String: Any])

        #expect(request.count == 3)
        #expect(Set(filter.keys) == ["kinds", "limit"])
        #expect(filter["kinds"] as? [Int] == [1])
        #expect(filter["limit"] as? Int == 50)
        await feed.close()
        await client.relays.disconnect()
    }

    @Test("an outbox subscription returns a sequence using the cached relay list")
    func outboxSubscriptionReturnsSequence() async throws {
        // .requirePresent keeps the gossip resolver from dialing relays that are
        // not already in the pool, so the test stays on the single mock relay.
        let (client, socket) = try await makeConnectedClient(gossipPolicy: .requirePresent)
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        // Publishing our own relay list caches it, so no relay-list fetch is needed.
        try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishRelayList(write: [self.relayURL])
        }
        let author = await client.identity.publicKey!

        let outbox = try await client.subscriptions.subscribe(
            filters: [Filter(authors: [author], kinds: [.textNote])], route: .outbox)
        #expect(outbox.expectedRelays == [relayURL])
        #expect(await client.activeSubscriptionCount == 1)
        await outbox.close()
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }
}
