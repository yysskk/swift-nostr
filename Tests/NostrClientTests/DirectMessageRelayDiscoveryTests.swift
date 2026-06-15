import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Direct Message Relay Discovery Tests (NIP-17, kind 10050)")
struct DirectMessageRelayDiscoveryTests {

    private func makeClient() async throws -> NostrClient {
        let client = NostrClient()
        try await client.setPrivateKey(String(repeating: "1", count: 64))
        return client
    }

    @Test("publishDirectMessageRelayList returns the published event and caches the list")
    func publishReturnsEventAndCaches() async throws {
        let client = try await makeClient()
        let published = try await client.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])

        #expect(published.event.kind == .directMessageRelayList)
        #expect(published.event.tags == [["relay", "wss://inbox.example.com"]])
        #expect(try published.event.verify())
        // Empty pool: nothing was targeted, so the result carries no statuses.
        #expect(published.result.statuses.isEmpty)

        let pubkey = await client.publicKey
        let cached = await client.cachedDirectMessageRelayList(for: pubkey!)
        #expect(cached?.relays == ["wss://inbox.example.com"])
    }

    @Test("publishDirectMessageRelayList accepts a DirectMessageRelayList value")
    func publishAcceptsListValue() async throws {
        let client = try await makeClient()
        let list = DirectMessageRelayList(relays: ["wss://a.example.com", "wss://b.example.com"])

        let published = try await client.publishDirectMessageRelayList(list)
        #expect(published.event.directMessageRelayList?.relays == list.relays)
    }

    @Test("cachedDirectMessageRelayList is nil before any fetch or publish")
    func cachedNilInitially() async {
        let client = NostrClient()
        #expect(await client.cachedDirectMessageRelayList(for: "somepubkey") == nil)
    }

    @Test("publishDirectMessageRelayList without a signer throws signerNotSet")
    func publishWithoutSignerThrows() async {
        let client = NostrClient()
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])
        }
    }
}
