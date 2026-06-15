import Foundation
import NostrCore

@testable import NostrClient

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// In-memory ``WebSocketSession`` that lets tests drive a ``RelayConnection``'s state
/// machine — connect, send, receive, publish-ack — without a live network relay.
final class MockWebSocketSession: WebSocketSession, @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [Result<WebSocketMessage, Error>] = []
    private var receiveWaiters: [CheckedContinuation<WebSocketMessage, Error>] = []
    private var sent: [WebSocketMessage] = []
    private var resumed = false
    private let pingError: Error?

    init(pingError: Error? = nil) {
        self.pingError = pingError
    }

    // MARK: - WebSocketSession

    func resume() {
        lock.lock()
        resumed = true
        lock.unlock()
    }

    func cancel(with closeCode: WebSocketCloseCode, reason: Data?) {
        lock.lock()
        let waiters = receiveWaiters
        receiveWaiters.removeAll()
        lock.unlock()
        // A cancelled socket makes a pending receive() fail, mirroring URLSession.
        for waiter in waiters {
            waiter.resume(throwing: URLError(.cancelled))
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        // `withLock` is the async-safe scoped form; the lock is never held across a suspension.
        lock.withLock {
            sent.append(message)
        }
    }

    func receive() async throws -> WebSocketMessage {
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

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        pongReceiveHandler(pingError)
    }

    // MARK: - Test driving

    /// Delivers a frame to the next `receive()` call (or buffers it for a future one).
    func deliver(_ message: WebSocketMessage) {
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

    /// Text frames captured from `send(_:)`.
    var sentTextFrames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sent.compactMap { frame in
            if case .string(let text) = frame { return text }
            return nil
        }
    }

    var didResume: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }
}

/// ``WebSocketSessionFactory`` that hands out test-controlled sockets.
///
/// Takes a producer (rather than a fixed instance) so a reconnection test can issue a
/// fresh socket per attempt instead of sharing one mock's buffers across reconnects.
struct MockWebSocketSessionFactory: WebSocketSessionFactory {
    let makeSession: @Sendable () -> MockWebSocketSession

    func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        makeSession()
    }
}
