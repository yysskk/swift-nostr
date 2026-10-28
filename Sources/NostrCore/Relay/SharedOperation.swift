/// One in-flight operation that concurrent callers join instead of repeating, superseding, or
/// being refused.
///
/// A NIP-46 `connect()` and a NIP-47 `fetchCapabilities()` both wait for something the peer sends
/// once: two tasks that need it should both get it from the same attempt. ``run(_:)`` starts the
/// operation on the first call and runs it on a task of its own; every call made while it is in
/// flight registers a waiter on that same attempt, and all of them receive its result — the value,
/// or the same error. The next call after it finishes starts a fresh attempt.
///
/// Cancellation is per caller. A caller whose task is cancelled stops waiting and throws the
/// configured cancellation error at once, but the attempt keeps running for the others: it ends
/// only on its own — success, its own timeout, the session ending. When the last remaining waiter
/// is cancelled nobody wants the result anymore, so the attempt's task is cancelled too, and a
/// later call starts a new one rather than joining an attempt that is shutting down.
///
/// The operation must tolerate being started again while an abandoned attempt is still winding
/// down: the abandoned attempt's result is discarded, but its task may still be running briefly
/// alongside the new one.
package actor SharedOperation<Success: Sendable, Failure: Error> {
    /// The work an attempt performs, reporting its outcome as a value so the attempt's task never
    /// throws.
    package typealias Operation = @Sendable () async -> Result<Success, Failure>

    private typealias Waiter = AsyncStream<Result<Success, Failure>>.Continuation

    /// The attempt in flight: its task and the callers waiting on it.
    private struct Attempt {
        let id: UInt64
        let task: Task<Void, Never>
        var waiters: [UInt64: Waiter] = [:]
    }

    private let cancelledError: Failure
    private var attempt: Attempt?
    private var nextID: UInt64 = 0

    /// Creates an idle shared operation.
    /// - Parameter cancelledError: What a caller whose task is cancelled throws.
    package init(cancelledError: Failure) {
        self.cancelledError = cancelledError
    }

    /// How many callers are waiting on the attempt in flight; `0` when none is.
    package var waiterCount: Int {
        attempt?.waiters.count ?? 0
    }

    /// Joins the attempt in flight, or starts one running `operation`, and returns its result.
    ///
    /// `operation` is used only when this call starts the attempt; a call that joins one ignores
    /// it.
    /// - Throws: The error the attempt fails with, or the cancellation error when the calling task
    ///   is cancelled — before joining, nothing is started.
    package func run(_ operation: @escaping Operation) async throws(Failure) -> Success {
        guard !Task.isCancelled else { throw cancelledError }

        let (stream, continuation) = AsyncStream<Result<Success, Failure>>.makeStream()
        let waiterID = makeID()
        var current = attempt ?? startAttempt(operation)
        current.waiters[waiterID] = continuation
        attempt = current

        // The attempt yields to every waiter, so the stream ends without a result only when this
        // caller's task is cancelled.
        for await result in stream {
            return try result.get()
        }
        withdraw(waiterID)
        throw cancelledError
    }

    private func startAttempt(_ operation: @escaping Operation) -> Attempt {
        let id = makeID()
        let task = Task {
            let result = await operation()
            finish(id, with: result)
        }
        return Attempt(id: id, task: task)
    }

    /// Delivers `result` to every waiter of attempt `id`, unless that attempt was abandoned.
    private func finish(_ id: UInt64, with result: Result<Success, Failure>) {
        guard let finished = attempt, finished.id == id else { return }
        attempt = nil
        for waiter in finished.waiters.values {
            waiter.yield(result)
            waiter.finish()
        }
    }

    /// Removes a cancelled caller, abandoning the attempt when it was the last one waiting.
    private func withdraw(_ waiterID: UInt64) {
        guard var current = attempt, current.waiters.removeValue(forKey: waiterID) != nil else { return }
        if current.waiters.isEmpty {
            current.task.cancel()
            attempt = nil
        } else {
            attempt = current
        }
    }

    private func makeID() -> UInt64 {
        nextID += 1
        return nextID
    }
}
