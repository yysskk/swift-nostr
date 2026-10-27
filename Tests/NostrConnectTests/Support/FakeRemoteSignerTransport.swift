import Foundation
import NostrCore

@testable import NostrConnect

/// An in-memory ``RelayTransport`` for tests.
///
/// It records what the session sends and subscribes to, and lets a test push simulated signer
/// events into the ``events()`` stream via ``deliver(_:)`` — no relay or network required.
actor FakeRemoteSignerTransport: RelayTransport {
    private(set) var isConnected = false
    private(set) var connectCount = 0
    private(set) var sentEvents: [Event] = []
    private(set) var subscriptions: [String: [Filter]] = [:]
    private var continuation: AsyncStream<Event>.Continuation?
    private var nextConnectError: RelayConnection.Error?
    private var nextSendError: RelayConnection.Error?

    init() {}

    func connect() async throws(RelayConnection.Error) {
        connectCount += 1
        if let error = nextConnectError {
            nextConnectError = nil
            throw error
        }
        isConnected = true
    }

    func subscribe(id: String, filters: [Filter]) async throws(RelayConnection.Error) {
        subscriptions[id] = filters
    }

    func unsubscribe(id: String) async {
        subscriptions[id] = nil
    }

    func send(_ event: Event) async throws(RelayConnection.Error) {
        if let error = nextSendError {
            nextSendError = nil
            throw error
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
    func deliver(_ event: Event) {
        continuation?.yield(event)
    }

    /// Ends the ``events()`` stream without disconnecting, standing in for every relay's message
    /// stream finishing because automatic reconnection gave up.
    func endEvents() {
        continuation?.finish()
        continuation = nil
    }

    /// Fails the next `connect()` with `error`, once.
    func failNextConnect(with error: RelayConnection.Error) {
        nextConnectError = error
    }

    /// Fails the next `send(_:)` with `error`, once.
    func failNextSend(with error: RelayConnection.Error) {
        nextSendError = error
    }

    /// The most recently sent event, if any.
    var lastSentEvent: Event? {
        sentEvents.last
    }
}
