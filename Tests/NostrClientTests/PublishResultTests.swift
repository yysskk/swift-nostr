import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Publish Result Tests")
struct PublishResultTests {

    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!

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

    @Test("status(for:) finds a relay under any spelling of its URL")
    func statusForEquivalentSpellings() throws {
        let result = PublishResult(statuses: [
            urlA: .accepted,
            urlB: .failed(NostrError.timeout),
        ])

        #expect(result.status(for: urlA) == .accepted)
        #expect(result.status(for: try RelayURL(string: "WSS://A.Example.com/")) == .accepted)
        #expect(result.status(for: try RelayURL(string: "wss://a.example.com:443")) == .accepted)
        #expect(result.status(for: urlB) == .failed(NostrError.timeout))

        // An untargeted relay reports nil.
        #expect(result.status(for: try RelayURL(string: "wss://unknown.example.com")) == nil)
    }
}
