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
    private var opened = false
    private var closed = false
    private let pingError: (any Error)?
    private let defersPing: Bool
    private var immediatePingsLeft: Int
    private var pendingPings: [CheckedContinuation<Void, any Error>] = []
    private var pingWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates a socket whose keepalive pings fail with `pingError`, or succeed when it is nil.
    ///
    /// With `defersPing`, `ping()` suspends until ``completePing(error:)`` answers it, so a test can
    /// suspend a connection attempt mid-handshake and act while it waits. A deferred ping ignores
    /// cancellation and closing the socket, like a transport whose pong callback never fires.
    /// `immediatePings` pings are answered at once before deferring starts — pass 1 to complete
    /// the connect handshake without racing its timeout and defer only the keepalive pings.
    public init(pingError: (any Error)? = nil, defersPing: Bool = false, immediatePings: Int = 0) {
        self.pingError = pingError
        self.defersPing = defersPing
        self.immediatePingsLeft = immediatePings
    }

    // MARK: - WebSocketSession

    public func open() {
        lock.lock()
        opened = true
        lock.unlock()
    }

    public func close(code: WebSocketCloseCode, reason: String?) {
        lock.lock()
        closed = true
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

    public func ping() async throws {
        let answersNow: Bool = lock.withLock {
            guard immediatePingsLeft > 0 else { return false }
            immediatePingsLeft -= 1
            return true
        }
        guard defersPing, !answersNow else {
            if let pingError { throw pingError }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            pendingPings.append(continuation)
            let waiters = pingWaiters
            pingWaiters.removeAll()
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
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

    /// Whether the handshake was started, i.e. `open()` has been called.
    public var didOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return opened
    }

    /// Whether `close(code:reason:)` has been called, i.e. the socket was closed rather than
    /// dropped while still open.
    public var didClose: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    // MARK: - Deferred ping

    /// Suspends until a deferred `ping()` is waiting for its pong, so a test can act at the exact
    /// point a connection attempt or keepalive is waiting on it.
    public func waitForPing() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if !pendingPings.isEmpty {
                lock.unlock()
                continuation.resume()
            } else {
                pingWaiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// How many deferred `ping()` calls are still waiting for their pong.
    public var pendingPingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingPings.count
    }

    /// Answers every deferred `ping()` waiting for its pong, failing them with `error` when one is
    /// given.
    public func completePing(error: (any Error)? = nil) {
        lock.lock()
        let pings = pendingPings
        pendingPings.removeAll()
        lock.unlock()
        for ping in pings {
            if let error {
                ping.resume(throwing: error)
            } else {
                ping.resume()
            }
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
