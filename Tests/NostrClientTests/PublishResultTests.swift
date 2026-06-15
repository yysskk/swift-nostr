import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Publish Result Tests")
struct PublishResultTests {

    private let urlA = URL(string: "wss://a.example.com")!
    private let urlB = URL(string: "wss://b.example.com")!
    private let urlC = URL(string: "wss://c.example.com")!

    @Test("accessors partition relays by status")
    func accessorsPartitionByStatus() {
        let result = PublishResult(statuses: [
            urlA: .accepted,
            urlB: .failed(NostrError.timeout),
            urlC: .pending,
        ])

        #expect(result.acceptedRelays == [urlA])
        #expect(result.failedRelays == [urlB])
        #expect(result.pendingRelays == [urlC])
        #expect(result.statuses[urlA] == .accepted)
        #expect(result.statuses[urlC] == .pending)
    }

    @Test("statuses compare by case only")
    func statusEquality() {
        #expect(PublishRelayStatus.accepted == .accepted)
        #expect(PublishRelayStatus.pending == .pending)
        #expect(PublishRelayStatus.failed(NostrError.timeout) == .failed(NostrError.notConnected))
        #expect(PublishRelayStatus.accepted != .pending)
        #expect(PublishRelayStatus.failed(NostrError.timeout) != .accepted)
    }

    @Test("accessors are empty for an empty result")
    func emptyResult() {
        let result = PublishResult(statuses: [:])
        #expect(result.acceptedRelays.isEmpty)
        #expect(result.failedRelays.isEmpty)
        #expect(result.pendingRelays.isEmpty)
    }

    @Test("publishing to an empty pool returns an empty result")
    func emptyPoolReturnsEmptyResult() async throws {
        let pool = RelayPool()
        let event = Event(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "test",
            sig: String(repeating: "c", count: 128)
        )

        let result = try await pool.publish(event)
        #expect(result.statuses.isEmpty)
    }
}
