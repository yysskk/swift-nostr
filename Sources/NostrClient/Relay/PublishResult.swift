import Foundation

/// Per-relay outcome of a publish.
public enum PublishRelayStatus: Sendable {
    /// The relay acknowledged the event (OK with accepted: true).
    case accepted

    /// Publishing to the relay failed (rejected, timed out, or not connected).
    case failed(Error)

    /// The relay had not settled yet when the publish strategy was satisfied.
    /// The send continues in the background; only its outcome is unobserved.
    case pending
}

extension PublishRelayStatus: Equatable {
    /// Compares by case only: two `.failed` values are equal regardless of the
    /// underlying error (`Error` itself is not `Equatable`).
    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.accepted, .accepted), (.failed, .failed), (.pending, .pending):
            return true
        default:
            return false
        }
    }
}

/// Summary of a publish across the targeted relays.
///
/// Returned by ``RelayPool/publish(_:to:strategy:)`` so callers can drive
/// per-relay delivery indicators or retry selectively. With an early-returning
/// strategy such as `.firstAck`, relays that were still in flight when the call
/// returned are reported as ``PublishRelayStatus/pending``.
public struct PublishResult: Sendable {
    /// Outcome per targeted relay URL.
    public let statuses: [URL: PublishRelayStatus]

    /// Relays that acknowledged the event before the call returned.
    public var acceptedRelays: Set<URL> {
        relays { if case .accepted = $0 { return true } else { return false } }
    }

    /// Relays whose publish had failed before the call returned.
    public var failedRelays: Set<URL> {
        relays { if case .failed = $0 { return true } else { return false } }
    }

    /// Relays that were still in flight when the call returned.
    public var pendingRelays: Set<URL> {
        relays { if case .pending = $0 { return true } else { return false } }
    }

    public init(statuses: [URL: PublishRelayStatus]) {
        self.statuses = statuses
    }

    private func relays(matching predicate: (PublishRelayStatus) -> Bool) -> Set<URL> {
        Set(statuses.filter { predicate($0.value) }.keys)
    }
}
