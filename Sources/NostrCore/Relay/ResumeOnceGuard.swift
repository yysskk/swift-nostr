import Foundation

/// Thread-safe one-shot flag guaranteeing a continuation is resumed exactly once.
///
/// `URLSessionWebSocketTask.sendPing(pongReceiveHandler:)` may invoke its handler
/// more than once when the socket is cancelled/aborted. Wrapping the resume in this
/// guard prevents a double `resume`, which would otherwise be a fatal
/// `SWIFT TASK CONTINUATION MISUSE`.
final class ResumeOnceGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var hasClaimed = false

    /// Returns `true` exactly once — for the first caller — and `false` thereafter.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if hasClaimed { return false }
        hasClaimed = true
        return true
    }
}
