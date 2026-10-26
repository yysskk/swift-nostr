import Foundation
import NostrCore

/// High-level subscription events emitted by `NostrClient`.
public enum SubscriptionEvent: Sendable {
    /// An event delivered by a relay for the subscription.
    case event(relayURL: RelayURL, event: Event)

    /// End of stored events for this subscription from a relay.
    case eose(relayURL: RelayURL)

    /// The relay closed this subscription.
    case closed(relayURL: RelayURL, message: String)

    /// A relay notice received while the subscription is active.
    case notice(relayURL: RelayURL, message: String)

    /// An authentication challenge received while the subscription is active.
    case auth(relayURL: RelayURL, challenge: String)

    /// The relay that emitted this subscription event.
    public var relayURL: RelayURL {
        switch self {
        case .event(let relayURL, _),
            .eose(let relayURL),
            .closed(let relayURL, _),
            .notice(let relayURL, _),
            .auth(let relayURL, _):
            relayURL
        }
    }
}
