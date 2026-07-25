import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("FakeRemoteSignerTransport Tests")
struct FakeRemoteSignerTransportTests {
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
}
