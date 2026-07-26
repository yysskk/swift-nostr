import Foundation
import NostrCore

@testable import NostrWalletConnect

/// An in-memory ``RelayTransport`` for tests.
///
/// It records what the connection sends and subscribes to, and lets a test push simulated wallet
/// events into the ``events()`` stream via ``emit(_:)`` — no relay or network required.
actor FakeWalletConnectTransport: RelayTransport {
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var sentEvents: [Event] = []
    private(set) var subscriptions: [String: [Filter]] = [:]
    /// How many events were sent before any subscription existed, so a test can prove that no
    /// command raced past the connection setup.
    private(set) var sendsBeforeSubscribe = 0
    private var continuation: AsyncStream<Event>.Continuation?
    private var isGateOpen = true
    private var gate: CheckedContinuation<Void, Never>?

    init() {}

    func connect() async throws {
        connectCount += 1
        if !isGateOpen {
            await withCheckedContinuation { gate = $0 }
        }
        isConnected = true
    }

    func subscribe(id: String, filters: [Filter]) async throws {
        subscriptions[id] = filters
    }

    func unsubscribe(id: String) async {
        subscriptions[id] = nil
    }

    func send(_ event: Event) async throws {
        if subscriptions.isEmpty {
            sendsBeforeSubscribe += 1
        }
        sentEvents.append(event)
    }

    func events() -> AsyncStream<Event> {
        // Finish any previous stream so an earlier consumer isn't left hanging.
        continuation?.finish()
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        return stream
    }

    func disconnect() async {
        isConnected = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Test controls

    /// Pushes a simulated incoming event to the ``events()`` stream.
    func emit(_ event: Event) {
        continuation?.yield(event)
    }

    /// Holds the next `connect()` open until ``openGate()``, so a test can keep the connection
    /// setup in flight while another command arrives.
    func closeGate() {
        isGateOpen = false
    }

    func openGate() {
        isGateOpen = true
        gate?.resume()
        gate = nil
    }

    /// The most recently sent event, if any.
    var lastSentEvent: Event? {
        sentEvents.last
    }
}
