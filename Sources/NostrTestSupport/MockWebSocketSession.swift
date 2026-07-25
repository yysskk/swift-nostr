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
    private let pingError: (any Error)?

    /// Creates a socket whose keepalive pings fail with `pingError`, or succeed when it is nil.
    public init(pingError: (any Error)? = nil) {
        self.pingError = pingError
    }

    // MARK: - WebSocketSession

    public func resume() {
        lock.lock()
        resumed = true
        lock.unlock()
    }

    public func cancel(with closeCode: WebSocketCloseCode, reason: Data?) {
        lock.lock()
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
        pongReceiveHandler(pingError)
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
