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
            filters: [Filter()], to: [RelayURL("WSS://Relay.Example.COM/")!])
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

    @Test("unsubscribe(subscriptionID:) finishes the stream")
    func unsubscribeFinishesStream() async throws {
        let (client, _) = try await makeConnectedClient()
        let subscription = try await client.subscriptions.subscribe(filters: [Filter()])

        let consumer = Task {
            for await _ in subscription {}
            return true
        }

        try await Task.sleep(for: .milliseconds(50))
        await client.subscriptions.unsubscribe(subscriptionID: subscription.id)

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

    @Test("convenience subscriptions return sequences")
    func convenienceSubscriptionsReturnSequences() async throws {
        let (client, _) = try await makeConnectedClient()

        let publicKey = PublicKey.fixture("author")
        let timeline = try await client.subscriptions.userTimeline(publicKey: publicKey)
        let global = try await client.subscriptions.globalFeed(limit: 10)
        let mentions = try await client.subscriptions.mentions(publicKey: publicKey)
        let metadata = try await client.subscriptions.metadata(publicKeys: [publicKey])

        #expect(await client.activeSubscriptionCount == 4)

        for subscription in [timeline, global, mentions, metadata] {
            await subscription.close()
        }
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("subscribeOutbox returns a sequence using the cached relay list")
    func subscribeOutboxReturnsSequence() async throws {
        // .requirePresent keeps the gossip resolver from dialing relays that are
        // not already in the pool, so the test stays on the single mock relay.
        let (client, socket) = try await makeConnectedClient(gossipPolicy: .requirePresent)
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        // Publishing our own relay list caches it, so no relay-list fetch is needed.
        try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishRelayList(write: [self.relayURL])
        }
        let author = await client.identity.publicKey!

        let outbox = try await client.routing.subscribeOutbox(authors: [author])
        #expect(await client.activeSubscriptionCount == 1)
        await outbox.close()
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("events(filters:) returns the filtered view directly")
    func eventsConvenienceReturnsFilteredView() async throws {
        let (client, _) = try await makeConnectedClient()
        let events = try await client.subscriptions.events(filters: [Filter()])
        #expect(await client.activeSubscriptionCount == 1)
        await events.close()
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("messages.giftWraps requires a signer")
    func subscribeToDirectMessagesRequiresSigner() async throws {
        let (client, _) = try await makeConnectedClient()
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.messages.giftWraps()
        }

        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        let messages = try await client.messages.giftWraps()
        #expect(await client.activeSubscriptionCount == 1)
        await messages.close()
        await client.relays.disconnect()
    }
}
