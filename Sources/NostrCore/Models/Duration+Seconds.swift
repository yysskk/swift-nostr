import Foundation

extension Duration {
    /// The whole seconds in the duration, truncated toward zero and clamped to `Int64`, the form
    /// Nostr documents carry periods in.
    ///
    /// `components` traps for a duration whose seconds overflow `Int64`; this saturates instead.
    package var wholeSeconds: Int64 {
        min(max(self, .seconds(Int64.min)), .seconds(Int64.max)).components.seconds
    }

    /// The duration as a `TimeInterval`, for Foundation APIs that take one.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
