import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Publish Result Tests")
struct PublishResultTests {

    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!
    private let urlD = RelayURL("wss://d.example.com")!

    @Test("accessors partition relays by status")
    func accessorsPartitionByStatus() {
        let result = PublishResult(statuses: [
            urlA: .accepted,
            urlB: .failed(.timedOut),
            urlC: .pending,
            urlD: .rejected(RelayRejection(status: "blocked: banned")),
        ])

        #expect(result.acceptedRelays == [urlA])
        #expect(result.failedRelays == [urlB, urlD])
        #expect(result.pendingRelays == [urlC])
        #expect(result.statuses[urlA] == .accepted)
        #expect(result.statuses[urlC] == .pending)
    }

    @Test("statuses compare by case and payload")
    func statusEquality() {
        let pow = RelayRejection(status: "pow: difficulty 20 required")
        #expect(PublishRelayStatus.accepted == .accepted)
        #expect(PublishRelayStatus.pending == .pending)
        #expect(PublishRelayStatus.accepted != .pending)
        #expect(PublishRelayStatus.failed(.timedOut) != .accepted)

        // The same case with the same payload is equal, and hashes alike.
        #expect(PublishRelayStatus.failed(.timedOut) == .failed(.timedOut))
        #expect(PublishRelayStatus.rejected(pow) == .rejected(RelayRejection(status: "pow: difficulty 20 required")))
        #expect(Set<PublishRelayStatus>([.rejected(pow), .rejected(pow), .failed(.timedOut)]).count == 2)

        // The same case with a different payload is not.
        #expect(PublishRelayStatus.failed(.timedOut) != .failed(.notConnected))
        #expect(PublishRelayStatus.rejected(pow) != .rejected(RelayRejection(status: "pow: difficulty 30 required")))
        #expect(PublishRelayStatus.rejected(pow) != .rejected(RelayRejection(prefix: .rateLimited, message: "")))
    }

    @Test("a relay's thrown error maps to the status that carries it")
    func statusForThrownError() {
        let rejection = RelayRejection(status: "auth-required: sign in")
        #expect(RelayPool.publishStatus(for: rejection) == .rejected(rejection))
        #expect(RelayPool.publishStatus(for: RelayConnection.Error.timedOut) == .failed(.timedOut))
        #expect(RelayPool.publishStatus(for: CancellationError()) == .failed(.notConnected))
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
            urlB: .failed(.timedOut),
        ])

        #expect(result.status(for: urlA) == .accepted)
        #expect(result.status(for: try RelayURL(string: "WSS://A.Example.com/")) == .accepted)
        #expect(result.status(for: try RelayURL(string: "wss://a.example.com:443")) == .accepted)
        #expect(result.status(for: urlB) == .failed(.timedOut))

        // An untargeted relay reports nil.
        #expect(result.status(for: try RelayURL(string: "wss://unknown.example.com")) == nil)
    }
}
