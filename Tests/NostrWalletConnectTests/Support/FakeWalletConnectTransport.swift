import Foundation
import NostrClient
import NostrCore

@testable import NostrWalletConnect

/// An in-memory ``WalletConnectTransport`` for tests.
///
/// It records what the connection sends and subscribes to, and lets a test push simulated wallet
/// events into the ``events()`` stream via ``emit(_:)`` — no relay or network required.
actor FakeWalletConnectTransport: WalletConnectTransport {
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var sentEvents: [Event] = []
    private(set) var subscriptions: [String: [Filter]] = [:]
    private var continuation: AsyncStream<Event>.Continuation?

    init() {}

    func connect() async throws {
        isConnected = true
        connectCount += 1
    }

    func subscribe(id: String, filters: [Filter]) async throws {
        subscriptions[id] = filters
    }

    func unsubscribe(id: String) async {
        subscriptions[id] = nil
    }

    func send(_ event: Event) async throws {
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

    /// The most recently sent event, if any.
    var lastSentEvent: Event? {
        sentEvents.last
    }
}
