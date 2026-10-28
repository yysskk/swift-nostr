import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Publish Strategy Tests")
struct PublishStrategyTests {

    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!

    private var dummyEvent: Event {
        Event(
            id: EventID(String(repeating: "a", count: 64))!,
            publicKey: PublicKey(String(repeating: "b", count: 64))!,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: 1,
            tags: [],
            content: "test",
            signature: Signature(String(repeating: "c", count: 128))!
        )
    }

    private func makePool() async throws -> RelayPool {
        let pool = RelayPool()
        await pool.add(urlA)
        await pool.add(urlB)
        await pool.add(urlC)
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
        #expect(RelayPoolConfig.default.queryTimeout == .seconds(10))
        #expect(RelayPoolConfig().queryTimeout == .seconds(10))
    }

    @Test("pool config accepts a custom default strategy")
    func customDefaultStrategy() {
        let config = RelayPoolConfig(defaultPublishStrategy: .allSettled)
        #expect(config.defaultPublishStrategy == .allSettled)
    }

    // MARK: - Publish behavior without a network

    @Test("publishing on an empty pool throws")
    func publishOnEmptyPoolThrows() async {
        let pool = RelayPool()
        await #expect(throws: RelayPool.Error.emptyPool) {
            try await pool.publish(self.dummyEvent)
        }
    }

    @Test("publishing to an empty target set throws")
    func publishToEmptyTargetSetThrows() async throws {
        let pool = try await makePool()
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            try await pool.publish(self.dummyEvent, to: [])
        }
    }

    @Test("a quorum publish that too few relays accept throws quorumNotMet with the counts")
    func quorumPublishBelowQuorumThrows() async throws {
        // One connected relay that acknowledges, plus one that was never connected and fails
        // fast: one acknowledgment against a quorum of two.
        let (client, socket) = try await ConnectedClientFixture.make(relayURL: urlA)
        let pool = await client.pool
        await pool.add(urlB)

        await #expect(throws: RelayPool.Error.quorumNotMet(acknowledged: 1, required: 2)) {
            try await PublishAckSupport.acknowledgingPublishes(on: socket) {
                try await pool.publish(self.dummyEvent, strategy: .quorum(2))
            }
        }
        await pool.disconnect()
    }

    @Test("publish on a disconnected connection fails fast with notConnected")
    func connectionPublishFailsFastWhenDisconnected() async {
        let connection = RelayConnection(url: urlA)
        await #expect(throws: RelayConnection.Error.notConnected) {
            try await connection.publish(self.dummyEvent)
        }
    }

    @Test(
        "publish on a pool of disconnected relays throws for every strategy",
        arguments: [PublishStrategy.firstAck, .quorum(2), .allSettled])
    func poolPublishThrowsWhenAllRelaysDisconnected(strategy: PublishStrategy) async throws {
        let pool = try await makePool()
        await #expect(throws: RelayConnection.Error.notConnected) {
            try await pool.publish(self.dummyEvent, strategy: strategy)
        }
    }

    // MARK: - Settled-publish failure evaluation

    @Test("all relays failing surfaces the last error")
    func publishFailureSurfacesLastError() {
        let error = RelayPool.publishFailure(
            successCount: 0, requiredAcks: 1, lastError: RelayConnection.Error.timedOut)
        #expect(error as? RelayConnection.Error == .timedOut)
    }

    @Test("partial success below the quorum fails with the quorum error")
    func publishFailureWhenQuorumNotMet() {
        let error = RelayPool.publishFailure(
            successCount: 1, requiredAcks: 2, lastError: RelayConnection.Error.timedOut)
        #expect(error as? RelayPool.Error == .quorumNotMet(acknowledged: 1, required: 2))
    }

    @Test("meeting the quorum succeeds despite other failures")
    func publishFailureNilWhenQuorumMet() {
        let error = RelayPool.publishFailure(
            successCount: 2, requiredAcks: 2, lastError: RelayConnection.Error.timedOut)
        #expect(error == nil)
    }

    @Test("allSettled succeeds when at least one relay accepted")
    func publishFailureNilForAllSettledWithOneSuccess() {
        let error = RelayPool.publishFailure(
            successCount: 1, requiredAcks: nil, lastError: RelayConnection.Error.timedOut)
        #expect(error == nil)
    }
}
