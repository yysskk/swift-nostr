import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The pool names every subscription itself, so callers can neither collide with each other nor
/// reuse an id whose CLOSE is still in flight.
@Suite("Relay Pool Subscription Tests")
struct RelayPoolSubscriptionTests {

    private func makePool() async throws -> (RelayPool, MockWebSocketSession) {
        let (client, socket) = try await ConnectedClientFixture.make()
        return (await client.pool, socket)
    }

    @Test("concurrent subscribes each get a distinct NIP-01 id, sent in their REQ")
    func concurrentSubscribesGetDistinctIDs() async throws {
        let (pool, socket) = try await makePool()

        let subscriptions = try await withThrowingTaskGroup(of: SubscriptionSequence.self) { group in
            for _ in 0..<20 {
                group.addTask { try await pool.subscribe(filters: [Filter(kinds: [1])]) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        let ids = Set(subscriptions.map(\.id))
        #expect(ids.count == 20)
        #expect(await pool.subscriptionCount == 20)
        for id in ids {
            #expect(!id.rawValue.isEmpty && id.rawValue.count <= 64)
            #expect(socket.sentTextFrames.contains { $0.hasPrefix(#"["REQ",""# + id.rawValue + #"","#) })
        }

        await pool.disconnect()
    }

    /// The listener has to be registered on the connection before the REQ goes out, or the events
    /// and the EOSE that answer it are dropped — and a fetch then waits out its whole timeout.
    @Test("a subscription receives an EOSE that follows its REQ immediately")
    func subscriptionReceivesImmediateEOSE() async throws {
        let (pool, socket) = try await makePool()
        let subscription = try await pool.subscribe(filters: [Filter(kinds: [1])])

        socket.deliver(.string(#"["EOSE","unrelated"]"#))
        socket.deliver(.string(#"["EOSE",""# + subscription.id.rawValue + #""]"#))

        var iterator = subscription.makeAsyncIterator()
        let first = await iterator.next()
        guard case .eose(let relayURL) = first else {
            Issue.record("expected the subscription's own EOSE, got \(String(describing: first))")
            return
        }
        #expect(relayURL == ConnectedClientFixture.defaultRelayURL)

        await pool.disconnect()
    }

    @Test("unsubscribe(id:) sends CLOSE for that id and ends the sequence")
    func unsubscribeByIDClosesAndEnds() async throws {
        let (pool, socket) = try await makePool()
        let kept = try await pool.subscribe(filters: [Filter(kinds: [1])])
        let closed = try await pool.subscribe(filters: [Filter(kinds: [1])])
        let drained = Task {
            for await _ in closed {}
        }

        await pool.unsubscribe(id: closed.id)
        await drained.value

        let closeFrames = socket.sentTextFrames.filter { $0.hasPrefix(#"["CLOSE""#) }
        #expect(closeFrames == [#"["CLOSE",""# + closed.id.rawValue + #""]"#])
        #expect(await pool.subscriptionCount == 1)
        #expect(await pool.listenerTaskCount(for: kept.id) == 1)
        #expect(await pool.listenerTaskCount(for: closed.id) == 0)

        // Unknown now, so a second call sends nothing more.
        await pool.unsubscribe(id: closed.id)
        #expect(socket.sentTextFrames.filter { $0.hasPrefix(#"["CLOSE""#) }.count == 1)

        await pool.disconnect()
    }

    @Test("disconnect() ends every subscription sequence")
    func disconnectEndsSequences() async throws {
        let (pool, _) = try await makePool()
        let subscription = try await pool.subscribe(filters: [Filter(kinds: [1])])
        let drained = Task {
            for await _ in subscription {}
        }

        await pool.disconnect()

        await drained.value
        #expect(await pool.subscriptionCount == 0)
    }
}
