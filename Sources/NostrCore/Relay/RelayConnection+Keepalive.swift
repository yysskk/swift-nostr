import Foundation

// MARK: - Keepalive
extension RelayConnection {
    /// Sends a WebSocket ping and waits for the pong, bounded by `timeout`.
    ///
    /// The ping runs in its own task so the wait never depends on ``WebSocketSession/ping()``
    /// returning: a transport may ignore cancellation, or its pong callback may never fire. The
    /// wait itself is a task group racing the ping's outcome against the timeout, and both of its
    /// children end promptly when cancelled — so the timeout, or cancelling the waiting task, ends
    /// the wait at once. A ping still running then is cancelled and left to finish on its own;
    /// closing the socket, which every failure path does, fails it on a real transport.
    static func pingSocket(_ socket: any WebSocketSession, timeout: Duration) async throws {
        let outcome = PingOutcome()
        let ping = Task {
            do {
                try await socket.ping()
                outcome.resolve(.success(()))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        defer { ping.cancel() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await outcome.value()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Error.timedOut
            }
            // The first child to finish decides; the other is cancelled and its result discarded.
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// Starts the periodic keepalive ping loop for the socket identified by `generation`.
    /// Replaces any previous keepalive so at most one runs per connection.
    func startKeepalive(generation: UInt64) {
        keepaliveTask?.cancel()
        let interval = config.pingInterval
        let pongTimeout = config.connectionTimeout
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                // Re-check after every suspension: the connection may have been
                // disconnected, failed, or replaced while this task slept.
                guard !Task.isCancelled, state == .connected, isCurrentSocket(generation),
                    let task = webSocketTask
                else { return }
                do {
                    try await Self.pingSocket(task, timeout: pongTimeout)
                } catch {
                    // A ping that raced a deliberate disconnect or reconnect is not a failure, and
                    // a ping belonging to a superseded socket says nothing about the live one.
                    guard !Task.isCancelled, state == .connected, isCurrentSocket(generation) else {
                        return
                    }
                    handleKeepaliveFailure(error)
                    return
                }
            }
        }
    }

    /// Tears the connection down after a failed keepalive ping and schedules a reconnect.
    private func handleKeepaliveFailure(_ error: any Swift.Error) {
        updateState(.failed(error.localizedDescription))
        // Cancel the socket so the receive loop's pending receive() exits promptly.
        discardSocket()
        scheduleReconnectIfNeeded()
    }
}

/// The one-shot result of a keepalive ping, awaited without depending on the ping's own task.
///
/// The first ``resolve(_:)`` wins and later ones are ignored, so the ping finishing, the waiter
/// being cancelled, and their races resume the waiting continuation exactly once.
private final class PingOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, any Swift.Error>?
    private var waiter: CheckedContinuation<Void, any Swift.Error>?

    /// Records `result` if none is recorded yet, resuming a suspended ``value()``.
    func resolve(_ result: Result<Void, any Swift.Error>) {
        let waiter: CheckedContinuation<Void, any Swift.Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    /// Suspends until a result is recorded; cancelling the caller records `CancellationError`.
    func value() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
                wait(with: continuation)
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    private func wait(with continuation: CheckedContinuation<Void, any Swift.Error>) {
        // Checked under the lock `resolve` takes, so a result recorded first is never missed.
        let recorded: Result<Void, any Swift.Error>? = lock.withLock {
            if result == nil { waiter = continuation }
            return result
        }
        if let recorded {
            continuation.resume(with: recorded)
        }
    }
}
