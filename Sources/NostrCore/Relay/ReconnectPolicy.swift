import Foundation

/// How a ``RelayConnection`` reconnects after its connection drops: how often it tries, and how
/// long it waits between attempts.
///
/// Delays grow exponentially from ``initialDelay`` by ``backoffMultiplier`` up to
/// ``maximumDelay``, and every wait is randomized downward by up to half so relays behind one
/// flaky uplink don't retry in lockstep.
public struct ReconnectPolicy: Sendable, Hashable {
    /// The number of reconnection attempts before giving up, or `nil` to keep trying.
    ///
    /// Zero or below means no attempt is made: the first drop is final.
    public var maximumAttempts: Int?

    /// The delay before the first reconnection attempt, floored at ``minimumDelay``.
    public var initialDelay: Duration

    /// The longest delay between reconnection attempts, never below ``initialDelay``.
    public var maximumDelay: Duration

    /// The factor each delay grows by. Values below 1, and NaN, are treated as 1.
    public var backoffMultiplier: Double

    /// Unlimited attempts, starting at 1 s and doubling up to 60 s.
    public static let `default` = ReconnectPolicy()

    /// The shortest a reconnect delay is allowed to be.
    ///
    /// `initialDelay: 0` reads like "reconnect immediately", but zero multiplied by any backoff
    /// stays zero — with unlimited attempts that is an unbounded loop hammering the relay with no
    /// pause at all. A negative delay does the same, since `Task.sleep` of one returns at once.
    public static let minimumDelay: Duration = .milliseconds(100)

    /// Creates a policy; every parameter defaults to the value ``default`` uses.
    /// - Parameters:
    ///   - maximumAttempts: The number of attempts before giving up, or `nil` to keep trying.
    ///   - initialDelay: The delay before the first reconnection attempt.
    ///   - maximumDelay: The longest delay between reconnection attempts.
    ///   - backoffMultiplier: The factor each delay grows by.
    public init(
        maximumAttempts: Int? = nil,
        initialDelay: Duration = .seconds(1),
        maximumDelay: Duration = .seconds(60),
        backoffMultiplier: Double = 2
    ) {
        self.maximumAttempts = maximumAttempts
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.backoffMultiplier = backoffMultiplier
    }
}

// MARK: - Bounds

extension ReconnectPolicy {
    /// Whether another attempt may follow `attempts` already made.
    func allowsAttempt(after attempts: Int) -> Bool {
        guard let maximumAttempts else { return true }
        return attempts < maximumAttempts
    }

    /// The delay to wait before the first reconnection attempt, floored so it always pauses.
    ///
    /// Resolved where it is read rather than in the initializer: every field is a `var`, so a
    /// value set afterwards would otherwise bypass validation done at init time.
    var resolvedInitialDelay: Duration {
        max(initialDelay, Self.minimumDelay)
    }

    /// The ceiling for reconnect delays, never below the initial delay.
    var resolvedMaximumDelay: Duration {
        max(maximumDelay, resolvedInitialDelay)
    }

    /// The backoff multiplier, floored at 1 so a delay can hold steady but never shrink.
    ///
    /// A multiplier of exactly 1 is a legitimate choice — retrying at a fixed rate — so it is left
    /// alone. Anything below it would walk the delay back toward zero, and NaN is treated as 1.
    var resolvedBackoffMultiplier: Double {
        backoffMultiplier.isNaN ? 1 : max(backoffMultiplier, 1)
    }

    /// The delay that follows `delay`: grown by the backoff multiplier and kept inside the bounds.
    ///
    /// Multiplying a `Duration` by an infinite or very large factor traps, so the growth is checked
    /// against the ceiling in floating point first and only multiplied exactly when it stays below.
    func nextDelay(after delay: Duration) -> Duration {
        let multiplier = resolvedBackoffMultiplier
        let ceiling = resolvedMaximumDelay
        guard delay.timeInterval * multiplier < ceiling.timeInterval else { return ceiling }
        return boundedDelay(delay * multiplier)
    }

    /// Applies `delay` to the floor and ceiling, keeping every wait inside the configured bounds.
    func boundedDelay(_ delay: Duration) -> Duration {
        min(max(delay, Self.minimumDelay), resolvedMaximumDelay)
    }
}
