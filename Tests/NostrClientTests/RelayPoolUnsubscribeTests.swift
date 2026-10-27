import Foundation
import NostrClient
import NostrCore
import NostrTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Ending a subscription must not wake relays that cannot be holding it: a CLOSE goes only to the
/// connected relays the REQ reached, and a disconnected relay is never reconnected just to receive one.
@Suite("Relay Pool Unsubscribe Tests")
struct RelayPoolUnsubscribeTests {

    /// Hands out one socket per relay host and counts each host's connection attempts.
    private final class PerRelaySockets: WebSocketSessionFactory, @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [String: [MockWebSocketSession]] = [:]

        func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
            let socket = MockWebSocketSession()
            lock.withLock { sockets[request.url?.host ?? "", default: []].append(socket) }
            return socket
        }

        func sockets(for url: RelayURL) -> [MockWebSocketSession] {
            lock.withLock { sockets[url.url.host ?? ""] ?? [] }
        }
    }

    private static let subscriptionID = "sub"

    private let holding = RelayURL("wss://holding.example.com")!
    private let dropped = RelayURL("wss://dropped.example.com")!
    private let lateConnected = RelayURL("wss://late-connected.example.com")!
    private let neverConnected = RelayURL("wss://never-connected.example.com")!

    private func closeFrames(on url: RelayURL, in sockets: PerRelaySockets) -> [String] {
        sockets.sockets(for: url).flatMap(\.sentTextFrames).filter { $0.hasPrefix(#"["CLOSE""#) }
    }

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RelayConnection.Error.timedOut
    }

    @Test("unsubscribe closes only on connected relays holding the subscription and reconnects none")
    func unsubscribeClosesOnlyHoldingRelays() async throws {
        let sockets = PerRelaySockets()
        let pool = RelayPool(
            config: RelayPoolConfig(
                defaultRelayConfig: RelayConnectionConfig(
                    connectionTimeout: .seconds(1), pingInterval: .seconds(60), autoReconnect: false)),
            webSocketFactory: sockets
        )

        let holdingConnection = await pool.addRelay(holding)
        let droppedConnection = await pool.addRelay(dropped)
        try await holdingConnection.connect()
        try await droppedConnection.connect()
        _ = try await pool.subscribe(subscriptionID: Self.subscriptionID, filters: [Filter(kinds: [1])]) { _ in }

        // Added after the REQ went out: one connected relay that never received it, and one
        // relay that was never connected at all.
        let lateConnection = await pool.addRelay(lateConnected)
        try await lateConnection.connect()
        await pool.addRelay(neverConnected)

        // The dropped relay held the subscription, but its socket — and the relay's REQ — is gone.
        try #require(sockets.sockets(for: dropped).count == 1)
        sockets.sockets(for: dropped)[0].deliver(error: URLError(.networkConnectionLost))
        try await pollUntil {
            if case .failed = await droppedConnection.state { return true }
            return false
        }

        await pool.unsubscribe(subscriptionID: Self.subscriptionID)

        #expect(closeFrames(on: holding, in: sockets).count == 1)
        #expect(closeFrames(on: dropped, in: sockets).isEmpty)
        #expect(closeFrames(on: lateConnected, in: sockets).isEmpty)
        // No relay was reconnected to send the CLOSE.
        #expect(sockets.sockets(for: dropped).count == 1)
        #expect(sockets.sockets(for: neverConnected).isEmpty)
        #expect(await pool.relay(for: neverConnected)?.state == .disconnected)
        #expect(await !droppedConnection.hasSubscription(Self.subscriptionID))
        await pool.disconnectAll()
    }
}
