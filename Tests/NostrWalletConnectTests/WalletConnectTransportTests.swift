import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnectTransport (Fake) Tests")
struct WalletConnectTransportTests {
    private func event(id: String, content: String = "x") -> Event {
        Event(
            id: id,
            pubkey: String(repeating: "0", count: 64),
            createdAt: 0,
            kind: .walletConnectResponse,
            tags: [],
            content: content,
            sig: "")
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
        try await transport.send(event(id: "aa"))
        try await transport.send(event(id: "bb"))
        #expect(await transport.sentEvents.map(\.id) == ["aa", "bb"])
        #expect(await transport.lastSentEvent?.id == "bb")
    }

    @Test("emit delivers events to the stream")
    func emitDelivers() async throws {
        let transport = FakeWalletConnectTransport()
        let stream = await transport.events()
        await transport.emit(event(id: "cc"))

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received?.id == "cc")
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
