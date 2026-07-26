import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Direct Message Relay Discovery Tests (NIP-17, kind 10050)")
struct DirectMessageRelayDiscoveryTests {

    /// A signed-in client backed by one connected mock relay that acks publishes.
    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        return (client, socket)
    }

    @Test("routing.publishDirectMessageRelayList returns the published event and caches the list")
    func publishReturnsEventAndCaches() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])
        }

        #expect(published.event.kind == .directMessageRelayList)
        #expect(published.event.tags == [["relay", "wss://inbox.example.com"]])
        #expect(try published.event.verify())
        #expect(published.result.acceptedRelays == [ConnectedClientFixture.defaultRelayURL])

        let pubkey = await client.identity.publicKey
        let cached = await client.routing.cachedDirectMessageRelayList(for: pubkey!)
        #expect(cached?.relays == ["wss://inbox.example.com"])
        await client.relays.disconnect()
    }

    @Test("routing.publishDirectMessageRelayList accepts a DirectMessageRelayList value")
    func publishAcceptsListValue() async throws {
        let (client, socket) = try await makeClient()
        let list = DirectMessageRelayList(relays: ["wss://a.example.com", "wss://b.example.com"])

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishDirectMessageRelayList(list)
        }
        #expect(published.event.directMessageRelayList?.relays == list.relays)
        await client.relays.disconnect()
    }

    @Test("cachedDirectMessageRelayList is nil before any fetch or publish")
    func cachedNilInitially() async {
        let client = NostrClient()
        #expect(await client.routing.cachedDirectMessageRelayList(for: "somepubkey") == nil)
    }

    @Test("routing.publishDirectMessageRelayList without a signer throws signerNotSet")
    func publishWithoutSignerThrows() async {
        let client = NostrClient()
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.routing.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])
        }
    }
}
