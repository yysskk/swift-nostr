import Foundation
import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// In-memory ``WebSocketSession`` that lets tests drive a ``RelayConnection``'s state
/// machine — connect, send, receive, publish-ack — without a live network relay.
public final class MockWebSocketSession: WebSocketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<WebSocketMessage, any Error>] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketMessage, any Error>] = []
    private var sent: [WebSocketMessage] = []
    private var resumed = false
    private var cancelled = false
    private let pingError: (any Error)?
    private let defersPing: Bool
    private var pendingPingHandlers: [@Sendable ((any Error)?) -> Void] = []
    private var pingWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a socket whose keepalive pings fail with `pingError`, or succeed when it is nil.
    ///
    /// With `defersPing`, `sendPing` holds its handler until ``completePing(error:)`` fires it,
    /// so a test can suspend a connection attempt mid-handshake and act while it waits.
    public init(pingError: (any Error)? = nil, defersPing: Bool = false) {
        self.pingError = pingError
        self.defersPing = defersPing
    }

    // MARK: - WebSocketSession

    public func resume() {
        lock.lock()
        resumed = true
        lock.unlock()
    }

    public func cancel(with closeCode: WebSocketCloseCode, reason: Data?) {
        lock.lock()
        cancelled = true
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        lock.unlock()
        // A cancelled socket makes a pending receive() fail, mirroring URLSession.
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }

    public func send(_ message: WebSocketMessage) async throws {
        // `withLock` is the async-safe scoped form; the lock is never held across a suspension.
        lock.withLock {
            sent.append(message)
        }
    }

    public func receive() async throws -> WebSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if queued.isEmpty {
                receiveWaiters.append(continuation)
                lock.unlock()
            } else {
                let next = queued.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            }
        }
    }

    public func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        guard defersPing else {
            pongReceiveHandler(pingError)
            return
        }
        lock.lock()
        pendingPingHandlers.append(pongReceiveHandler)
        let waiters = pingWaiters
        pingWaiters.removeAll()
        lock.unlock()
        for waiter in waiters {
            waiter.resume()
        }
    }

    // MARK: - Test driving

    /// Delivers a frame to the next `receive()` call (or buffers it for a future one).
    public func deliver(_ message: WebSocketMessage) {
        lock.lock()
        if receiveWaiters.isEmpty {
            queued.append(.success(message))
            lock.unlock()
        } else {
            let waiter = receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(returning: message)
        }
    }

    /// Fails the next `receive()` call (or buffers the failure), simulating the
    /// transport erroring out — e.g. a dropped connection.
    public func deliver(error: any Error) {
        lock.lock()
        if receiveWaiters.isEmpty {
            queued.append(.failure(error))
            lock.unlock()
        } else {
            let waiter = receiveWaiters.removeFirst()
            lock.unlock()
            waiter.resume(throwing: error)
        }
    }

    /// Text frames captured from `send(_:)`.
    public var sentTextFrames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { frame in
            if case .string(let text) = frame { return text }
            return nil
        }
    }

    /// Whether the handshake was started, i.e. `resume()` has been called.
    public var didResume: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }

    /// Whether `cancel(with:reason:)` has been called, i.e. the socket was closed rather than
    /// dropped while still open.
    public var didCancel: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    // MARK: - Deferred ping

    /// Suspends until a deferred `sendPing` has registered its handler, so a test can act at the
    /// exact point a connection attempt is waiting on its pong.
    public func waitForPing() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !pendingPingHandlers.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                pingWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Fires every handler a deferred `sendPing` is holding, completing the pong.
    public func completePing(error: (any Error)? = nil) {
        lock.lock()
        let handlers = pendingPingHandlers
        pendingPingHandlers.removeAll()
        lock.unlock()
        for handler in handlers {
            handler(error)
        }
    }
}

/// ``WebSocketSessionFactory`` that hands out test-controlled sockets.
///
/// Takes a producer (rather than a fixed instance) so a reconnection test can issue a
/// fresh socket per attempt instead of sharing one mock's buffers across reconnects.
public struct MockWebSocketSessionFactory: WebSocketSessionFactory {
    public let makeSession: @Sendable () -> MockWebSocketSession

    /// Creates a factory that calls `makeSession` once per connection attempt.
    public init(makeSession: @escaping @Sendable () -> MockWebSocketSession) {
        self.makeSession = makeSession
    }

    public func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        makeSession()
    }
}
