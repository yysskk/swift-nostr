import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NostrClient Targeted Publish Tests")
struct NostrClientTargetedPublishTests {

    private let urlA = RelayURL("wss://a.example.com")!
    private let urlB = RelayURL("wss://b.example.com")!
    private let urlC = RelayURL("wss://c.example.com")!

    // MARK: - Fixtures

    /// A client whose pool holds one connected relay per URL, paired with the socket driving it.
    /// Relays connect one at a time so each pairs with a known socket.
    private func makeClient(
        relayURLs: [RelayURL]
    ) async throws -> (client: NostrClient, sockets: [MockWebSocketSession]) {
        let sockets = relayURLs.map { _ in MockWebSocketSession() }
        let counter = SocketCounter()
        let pool = RelayPool(
            config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets[counter.next()] })
        )
        for url in relayURLs {
            try await pool.addRelay(url).connect()
        }
        return (NostrClient(relayPool: pool), sockets)
    }

    private func makeEvent() throws -> Event {
        try EventSigner(keyPair: try KeyPair()).signTextNote(content: "targeted")
    }

    // MARK: - Targeting

    @Test("publishing to chosen relays reaches only those relays")
    func publishReachesOnlyTargetedRelays() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA, urlB, urlC])
        let event = try makeEvent()

        let task = Task {
            try await client.events.publish(
                event, to: [RelayURL("wss://a.example.com")!, RelayURL("wss://c.example.com")!], strategy: .allSettled)
        }
        let sentToA = try await PublishAckSupport.acknowledgePublish(on: sockets[0])
        let sentToC = try await PublishAckSupport.acknowledgePublish(on: sockets[2])
        let result = try await task.value

        #expect(sentToA.id == event.id)
        #expect(sentToC.id == event.id)
        #expect(result.acceptedRelays == [urlA, urlC])
        // The pooled but untargeted relay never saw the event.
        #expect(PublishAckSupport.eventFrames(in: sockets[1]).isEmpty)
        await client.relays.disconnect()
    }

    @Test("a target spelled differently from the pool key still matches the pooled relay")
    func publishMatchesAlternateSpelling() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA, urlB])
        let event = try makeEvent()

        // Upper-case host and a root trailing slash normalize to relay A's pool key.
        let result = try await PublishAckSupport.acknowledgingPublishes(on: sockets[0]) {
            try await client.events.publish(event, to: [RelayURL("wss://A.EXAMPLE.COM/")!], strategy: .allSettled)
        }

        #expect(result.acceptedRelays == [urlA])
        #expect(PublishAckSupport.eventFrames(in: sockets[1]).isEmpty)
        await client.relays.disconnect()
    }

    @Test("targets not in the pool are skipped while pooled ones are published to")
    func publishSkipsTargetsNotInPool() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA, urlB])
        let event = try makeEvent()

        let result = try await PublishAckSupport.acknowledgingPublishes(on: sockets[0]) {
            try await client.events.publish(
                event, to: [RelayURL("wss://a.example.com")!, RelayURL("wss://unknown.example.com")!],
                strategy: .allSettled)
        }

        // The unknown relay is neither connected on demand nor reported.
        #expect(Set(result.statuses.keys) == [urlA])
        #expect(await client.relays.relayCount == 2)
        #expect(PublishAckSupport.eventFrames(in: sockets[1]).isEmpty)
        await client.relays.disconnect()
    }

    @Test("nil targets broadcast to the whole pool")
    func publishWithNilTargetsBroadcasts() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA, urlB, urlC])
        let event = try makeEvent()

        let task = Task { try await client.events.publish(event, to: nil, strategy: .allSettled) }
        for socket in sockets {
            try await PublishAckSupport.acknowledgePublish(on: socket)
        }
        let result = try await task.value

        #expect(result.acceptedRelays == [urlA, urlB, urlC])
        await client.relays.disconnect()
    }

    // MARK: - Failures

    @Test("an empty target list throws instead of broadcasting")
    func publishToEmptyTargetsThrows() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA, urlB])
        let event = try makeEvent()

        await #expect(throws: NostrError.noMatchingRelays([])) {
            try await client.events.publish(event, to: [])
        }
        #expect(sockets.allSatisfy { PublishAckSupport.eventFrames(in: $0).isEmpty })
        await client.relays.disconnect()
    }

    @Test("a target not in the pool throws noMatchingRelays")
    func publishToUnknownRelayThrows() async throws {
        let (client, sockets) = try await makeClient(relayURLs: [urlA])
        let event = try makeEvent()

        await #expect(throws: NostrError.noMatchingRelays([RelayURL("wss://unknown.example.com")!])) {
            try await client.events.publish(event, to: [RelayURL("wss://Unknown.Example.com/")!])
        }
        #expect(PublishAckSupport.eventFrames(in: sockets[0]).isEmpty)
        #expect(await client.relays.relayCount == 1)
        await client.relays.disconnect()
    }
}

/// Hands out incrementing indexes to a factory closure that must stay `@Sendable`.
private final class SocketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var index = -1

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        index += 1
        return index
    }
}
