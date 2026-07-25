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
}
