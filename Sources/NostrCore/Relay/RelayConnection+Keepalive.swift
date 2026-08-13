import Foundation

// MARK: - Keepalive
extension RelayConnection {
    /// Sends a WebSocket ping and waits for the pong, bounded by `timeout`.
    ///
    /// `sendPing` can invoke its handler multiple times when the socket is
    /// cancelled/aborted (e.g. errno 53 "Software caused connection abort"), the
    /// timeout watchdog races the handler, and task cancellation races both — so
    /// ``ResumeOnceGuard`` arbitrates every resume site to fire exactly once.
    /// Cancelling the waiting task resumes immediately with `CancellationError`
    /// instead of staying suspended until the pong or the watchdog fires.
    static func pingSocket(_ task: any WebSocketSession, timeout: TimeInterval) async throws {
        let resumeGuard = ResumeOnceGuard()
        let cancellationBox = PingCancellationBox()
        // Held outside the continuation so the cancellation handler can stop the watchdog too.
        // Left running, it sleeps out the full timeout after the wait is already over — so
        // cancelling a connect did not actually release its resources for up to that long.
        let watchdogBox = PingWatchdogBox()
        defer { watchdogBox.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                guard cancellationBox.register(continuation) else {
                    // The task was cancelled before the wait began; onCancel found
                    // nothing to resume, so it is this path's job.
                    guard resumeGuard.claim() else { return }
                    continuation.resume(throwing: CancellationError())
                    return
                }
                watchdogBox.store(
                    Task {
                        try? await Task.sleep(for: .seconds(timeout))
                        guard resumeGuard.claim() else { return }
                        continuation.resume(throwing: NostrError.timeout)
                    })
                task.sendPing { error in
                    guard resumeGuard.claim() else { return }
                    watchdogBox.cancel()
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            watchdogBox.cancel()
            guard let continuation = cancellationBox.cancel() else { return }
            guard resumeGuard.claim() else { return }
            continuation.resume(throwing: CancellationError())
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
                try? await Task.sleep(for: .seconds(interval))
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
    private func handleKeepaliveFailure(_ error: any Error) {
        updateState(.failed(error.localizedDescription))
        // Cancel the socket so the receive loop's pending receive() exits promptly.
        discardSocket()
        scheduleReconnectIfNeeded()
    }
}

/// Holds the ping's timeout watchdog so every exit — pong, cancellation, or returning normally —
/// can stop it, whichever happens first.
private final class PingWatchdogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var isCancelled = false

    /// Stores the watchdog, cancelling it immediately if this box was already cancelled.
    func store(_ task: Task<Void, Never>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            task.cancel()
            return
        }
        self.task = task
        lock.unlock()
    }

    /// Cancels the watchdog, and marks the box so a later `store` cancels on arrival.
    func cancel() {
        lock.lock()
        isCancelled = true
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

/// Hands the ping continuation from the suspension point to the task-cancellation
/// handler, closing the race where cancellation fires before the continuation exists.
///
/// `register` returns `false` when cancellation already happened, telling the caller
/// to resume the continuation itself; `cancel` marks the box cancelled and takes the
/// continuation if one was registered. Exactly-once resumption across the pong
/// handler, the watchdog, and cancellation remains the job of ``ResumeOnceGuard``.
private final class PingCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var isCancelled = false

    /// Stores the continuation for a later `cancel`; returns `false` if the task
    /// was already cancelled (the continuation is not stored).
    func register(_ continuation: CheckedContinuation<Void, any Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled { return false }
        self.continuation = continuation
        return true
    }

    /// Marks the box cancelled and returns the registered continuation, if any.
    func cancel() -> CheckedContinuation<Void, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        isCancelled = true
        let continuation = self.continuation
        self.continuation = nil
        return continuation
    }
}
