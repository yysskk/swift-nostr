import Foundation
import NostrCore

/// Per-relay outcome of a publish.
///
/// Statuses compare by value: two ``rejected(_:)`` statuses are equal only when their rejections
/// are, and two ``failed(_:)`` statuses only when their errors are. To test for a case regardless
/// of its payload, match it: `if case .rejected = status { ... }`.
public enum PublishRelayStatus: Sendable, Hashable {
    /// The relay acknowledged the event (OK with accepted: true).
    case accepted

    /// The relay answered OK `false`; branch on the rejection's ``RelayRejection/prefix`` to learn
    /// why.
    case rejected(RelayRejection)

    /// Publishing to the relay failed without an answer from it, such as
    /// ``RelayConnection/Error/timedOut`` or ``RelayConnection/Error/notConnected``.
    case failed(RelayConnection.Error)

    /// The relay had not settled yet when the publish strategy was satisfied.
    /// The send continues in the background; only its outcome is unobserved.
    case pending
}

/// Summary of a publish across the targeted relays.
///
/// Returned by ``RelayPool/publish(_:to:strategy:)`` so callers can drive
/// per-relay delivery indicators or retry selectively. With an early-returning
/// strategy such as `.firstAck`, relays that were still in flight when the call
/// returned are reported as ``PublishRelayStatus/pending``.
public struct PublishResult: Sendable, Hashable {
    /// Outcome per targeted relay.
    public let statuses: [RelayURL: PublishRelayStatus]

    /// The status for a relay, or nil when the relay was not targeted.
    public func status(for relayURL: RelayURL) -> PublishRelayStatus? {
        statuses[relayURL]
    }

    /// Relays that acknowledged the event before the call returned.
    public var acceptedRelays: Set<RelayURL> {
        relays { if case .accepted = $0 { return true } else { return false } }
    }

    /// Relays that had rejected the event or failed before the call returned: every relay whose
    /// status is ``PublishRelayStatus/rejected(_:)`` or ``PublishRelayStatus/failed(_:)``.
    public var failedRelays: Set<RelayURL> {
        relays {
            switch $0 {
            case .rejected, .failed: true
            case .accepted, .pending: false
            }
        }
    }

    /// Relays that were still in flight when the call returned.
    public var pendingRelays: Set<RelayURL> {
        relays { if case .pending = $0 { return true } else { return false } }
    }

    /// Creates a result from per-relay outcomes.
    public init(statuses: [RelayURL: PublishRelayStatus]) {
        self.statuses = statuses
    }

    private func relays(matching predicate: (PublishRelayStatus) -> Bool) -> Set<RelayURL> {
        Set(statuses.filter { predicate($0.value) }.keys)
    }
}
