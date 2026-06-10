import Foundation

/// Determines when ``RelayPool/publish(_:to:strategy:)`` returns.
///
/// The event is always sent to every targeted relay regardless of the strategy;
/// the strategy only controls how many acknowledgments to wait for before returning.
public enum PublishStrategy: Sendable, Equatable {
    /// Returns as soon as one relay acknowledges the event (OK with accepted: true).
    /// Sends to the remaining relays continue in the background for redundancy.
    case firstAck

    /// Returns as soon as `count` relays acknowledge the event.
    /// The count is clamped to `1...targetCount`. Throws if fewer relays
    /// acknowledge after all targets settle.
    case quorum(Int)

    /// Waits for every targeted relay to settle (accept, reject, or time out).
    /// Succeeds if at least one relay accepted the event.
    case allSettled

    /// The number of acknowledgments required before returning early,
    /// or `nil` to wait for all targets to settle.
    func requiredAcks(targetCount: Int) -> Int? {
        switch self {
        case .firstAck:
            return 1
        case .quorum(let count):
            return min(max(count, 1), targetCount)
        case .allSettled:
            return nil
        }
    }
}
