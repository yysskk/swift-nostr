import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrWalletConnect

@Suite("FakeWalletConnectTransport Tests")
struct FakeWalletConnectTransportTests {
    private func event(id: EventID, content: String = "x") -> Event {
        Event(
            id: id,
            publicKey: .fixture("author"),
            createdAt: Timestamp(rawValue: 0),
            kind: .walletConnectResponse,
            tags: [],
            content: content,
            signature: nil)
    }

    @Test("connect and disconnect toggle the connected flag")
    func connectDisconnect() async throws {
        let transport = FakeWalletConnectTransport()
        #expect(await transport.isConnected == false)
        try await transport.connect()
        #expect(await transport.isConnected == true)
        await transport.disconnect()
        #expect(await transport.isConnected == false)
    }

    @Test("subscribe and unsubscribe track subscriptions")
    func subscriptions() async throws {
        let transport = FakeWalletConnectTransport()
        try await transport.subscribe(id: "sub", filters: [Filter(kinds: [.walletConnectResponse])])
        #expect(await transport.subscriptions["sub"]?.count == 1)
        await transport.unsubscribe(id: "sub")
        #expect(await transport.subscriptions["sub"] == nil)
    }

    @Test("send records published events")
    func sendRecords() async throws {
        let transport = FakeWalletConnectTransport()
        try await transport.send(event(id: .fixture("aa")))
        try await transport.send(event(id: .fixture("bb")))
        #expect(await transport.sentEvents.map(\.id) == [.fixture("aa"), .fixture("bb")])
        #expect(await transport.lastSentEvent?.id == .fixture("bb"))
    }

    @Test("emit delivers events to the stream")
    func emitDelivers() async throws {
        let transport = FakeWalletConnectTransport()
        let stream = await transport.events()
        await transport.emit(event(id: .fixture("cc")))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.id == .fixture("cc"))
    }

    @Test("disconnect finishes the events stream")
    func disconnectFinishesStream() async throws {
        let transport = FakeWalletConnectTransport()
        let stream = await transport.events()
        await transport.disconnect()

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }

    @Test("a second events() call finishes the previous stream")
    func secondEventsFinishesFirst() async throws {
        let transport = FakeWalletConnectTransport()
        let first = await transport.events()
        _ = await transport.events()

        var iterator = first.makeAsyncIterator()
        let next = await iterator.next()
        #expect(next == nil)
    }
}
