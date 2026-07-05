import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("RemoteSignerTransport Tests")
struct RelayConnectionTransportTests {
    private func event(id: String, content: String = "x") -> Event {
        Event(
            id: id,
            pubkey: String(repeating: "0", count: 64),
            createdAt: 0,
            kind: .nostrConnect,
            tags: [],
            content: content,
            sig: "")
    }

    // MARK: - Fake transport

    @Test("connect and disconnect toggle the connected flag")
    func connectDisconnect() async throws {
        let transport = FakeRemoteSignerTransport()
        #expect(await transport.isConnected == false)
        try await transport.connect()
        #expect(await transport.isConnected == true)
        await transport.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test("subscribe and unsubscribe track subscriptions")
    func subscriptions() async throws {
        let transport = FakeRemoteSignerTransport()
        try await transport.subscribe(id: "sub", filters: [Filter(kinds: [.nostrConnect])])
        #expect(await transport.subscriptions["sub"]?.count == 1)
        await transport.unsubscribe(id: "sub")
        #expect(await transport.subscriptions["sub"] == nil)
    }

    @Test("send records published events")
    func sendRecords() async throws {
        let transport = FakeRemoteSignerTransport()
        try await transport.send(event(id: "aa"))
        try await transport.send(event(id: "bb"))
        #expect(await transport.sentEvents.map(\.id) == ["aa", "bb"])
        #expect(await transport.lastSentEvent?.id == "bb")
    }

    @Test("deliver forwards events to the stream")
    func deliverForwards() async throws {
        let transport = FakeRemoteSignerTransport()
        let stream = await transport.events()
        await transport.deliver(event(id: "cc"))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.id == "cc")
    }

    @Test("disconnect finishes the events stream")
    func disconnectFinishesStream() async throws {
        let transport = FakeRemoteSignerTransport()
        let stream = await transport.events()
        await transport.disconnect()

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("a second events() call finishes the previous stream")
    func secondEventsFinishesFirst() async throws {
        let transport = FakeRemoteSignerTransport()
        let first = await transport.events()
        _ = await transport.events()

        var iterator = first.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    // MARK: - Default RelayConnectionTransport

    @Test("connect throws notConnected when there are no relays")
    func connectWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: RemoteSignerError.notConnected) {
            try await transport.connect()
        }
    }

    @Test("subscribe throws notConnected when there are no relays")
    func subscribeWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: RemoteSignerError.notConnected) {
            try await transport.subscribe(id: "sub", filters: [Filter(kinds: [.nostrConnect])])
        }
    }

    @Test("send throws notConnected when there are no relays")
    func sendWithoutRelaysThrows() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await #expect(throws: RemoteSignerError.notConnected) {
            try await transport.send(event(id: "aa"))
        }
    }

    @Test("events() finishes immediately when there are no relays")
    func eventsWithoutRelaysFinishes() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        let stream = await transport.events()

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("disconnect is safe when there are no relays")
    func disconnectWithoutRelays() async {
        let transport = RelayConnectionTransport(relayURLs: [])
        await transport.disconnect()
    }
}
