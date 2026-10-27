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

    /// The hang: `relays.disconnect()` cancelled the pool's listeners but left the subscription's
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

        #expect(await client.activeSubscriptionCount == 1)

        await client.relays.disconnect()
        withExtendedLifetime(subscription) {}

        // Retained, this grew on every connect/disconnect cycle while naming subscriptions the
        // pool could no longer serve.
        #expect(await client.activeSubscriptionCount == 0)
    }
}
