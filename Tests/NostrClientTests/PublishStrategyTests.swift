import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Publish Strategy Tests")
struct PublishStrategyTests {

    private let urlA = URL(string: "wss://a.example.com")!
    private let urlB = URL(string: "wss://b.example.com")!
    private let urlC = URL(string: "wss://c.example.com")!

    private var dummyEvent: Event {
        Event(
            id: String(repeating: "a", count: 64),
            pubkey: String(repeating: "b", count: 64),
            createdAt: 1_700_000_000,
            kind: 1,
            tags: [],
            content: "test",
            sig: String(repeating: "c", count: 128)
        )
    }

    private func makePool() async -> RelayPool {
        let pool = RelayPool()
        await pool.addRelay(url: urlA)
        await pool.addRelay(url: urlB)
        await pool.addRelay(url: urlC)
        return pool
    }

    // MARK: - requiredAcks semantics

    @Test("firstAck requires exactly one acknowledgment")
    func firstAckRequiresOne() {
        #expect(PublishStrategy.firstAck.requiredAcks(targetCount: 1) == 1)
        #expect(PublishStrategy.firstAck.requiredAcks(targetCount: 10) == 1)
    }

    @Test("quorum is clamped to the target count")
    func quorumClampsToTargetCount() {
        #expect(PublishStrategy.quorum(2).requiredAcks(targetCount: 3) == 2)
        #expect(PublishStrategy.quorum(99).requiredAcks(targetCount: 3) == 3)
        #expect(PublishStrategy.quorum(3).requiredAcks(targetCount: 3) == 3)
    }

    @Test("quorum is clamped to at least one acknowledgment")
    func quorumClampsToAtLeastOne() {
        #expect(PublishStrategy.quorum(0).requiredAcks(targetCount: 3) == 1)
        #expect(PublishStrategy.quorum(-5).requiredAcks(targetCount: 3) == 1)
        #expect(PublishStrategy.quorum(5).requiredAcks(targetCount: 0) == 1)
    }

    @Test("allSettled waits for every target")
    func allSettledWaitsForAll() {
        #expect(PublishStrategy.allSettled.requiredAcks(targetCount: 1) == nil)
        #expect(PublishStrategy.allSettled.requiredAcks(targetCount: 10) == nil)
    }

    // MARK: - Configuration

    @Test("default pool config uses firstAck")
    func defaultStrategyIsFirstAck() {
        #expect(RelayPoolConfig.default.defaultPublishStrategy == .firstAck)
        #expect(RelayPoolConfig().defaultPublishStrategy == .firstAck)
    }

    @Test("pool config accepts a custom default strategy")
    func customDefaultStrategy() {
        let config = RelayPoolConfig(defaultPublishStrategy: .allSettled)
        #expect(config.defaultPublishStrategy == .allSettled)
    }

    // MARK: - Publish behavior without a network

    @Test("publishing to an empty pool is a no-op")
    func publishToEmptyPoolIsNoOp() async throws {
        let pool = RelayPool()
        try await pool.publish(dummyEvent)
    }

    @Test("publishing to an empty target set is a no-op")
    func publishToEmptyTargetSetIsNoOp() async throws {
        let pool = await makePool()
        try await pool.publish(dummyEvent, to: [])
    }

    @Test("publish on a disconnected connection fails fast with notConnected")
    func connectionPublishFailsFastWhenDisconnected() async {
        let connection = RelayConnection(url: urlA)
        await #expect(throws: NostrError.notConnected) {
            try await connection.publish(self.dummyEvent)
        }
    }

    @Test(
        "publish on a pool of disconnected relays throws for every strategy",
        arguments: [PublishStrategy.firstAck, .quorum(2), .allSettled])
    func poolPublishThrowsWhenAllRelaysDisconnected(strategy: PublishStrategy) async {
        let pool = await makePool()
        await #expect(throws: NostrError.notConnected) {
            try await pool.publish(self.dummyEvent, strategy: strategy)
        }
    }

    // MARK: - Settled-publish failure evaluation

    @Test("all relays failing surfaces the last error")
    func publishFailureSurfacesLastError() {
        let error = RelayPool.publishFailure(
            successCount: 0, requiredAcks: 1, lastError: NostrError.timeout)
        #expect(error as? NostrError == .timeout)
    }

    @Test("partial success below the quorum fails with the quorum error")
    func publishFailureWhenQuorumNotMet() {
        let error = RelayPool.publishFailure(
            successCount: 1, requiredAcks: 2, lastError: NostrError.timeout)
        #expect(error as? NostrError == .relayError("Publish quorum not met: 1/2 relays acknowledged"))
    }

    @Test("meeting the quorum succeeds despite other failures")
    func publishFailureNilWhenQuorumMet() {
        let error = RelayPool.publishFailure(
            successCount: 2, requiredAcks: 2, lastError: NostrError.timeout)
        #expect(error == nil)
    }

    @Test("allSettled succeeds when at least one relay accepted")
    func publishFailureNilForAllSettledWithOneSuccess() {
        let error = RelayPool.publishFailure(
            successCount: 1, requiredAcks: nil, lastError: NostrError.timeout)
        #expect(error == nil)
    }
}
