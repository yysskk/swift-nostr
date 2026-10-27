import Foundation
import NostrCore

/// Which relays a publish, fetch, count, or subscription goes to.
///
/// ```swift
/// try await client.events.publish(.textNote("gm"))                          // .pool
/// try await client.events.publish(.textNote("gm"), route: .relays([relay]))  // only that relay
/// let feed = try await client.subscriptions.subscribe(
///     filters: [Filter(authors: follows, kinds: [.textNote])], route: .outbox)
/// ```
public enum RelayRoute: Sendable, Hashable {
    /// Every relay in the pool.
    case pool

    /// Exactly these relays.
    ///
    /// Relays not in the pool are skipped, not connected on demand: add them with
    /// ``NostrRelaysAPI/add(_:config:)`` first. When none of them is in the pool — an empty set
    /// included — the operation throws ``RelayPool/Error/noMatchingRelays(_:)`` instead of falling
    /// back to the whole pool.
    case relays(Set<RelayURL>)

    /// The NIP-65 outbox model, resolved from the relay lists (kind 10002) of the keys involved.
    ///
    /// Relay lists not cached are fetched first, and the resolved relays are connected per the
    /// client's ``GossipRelayPolicy``.
    /// - A publish goes to the author's WRITE relays plus the READ (inbox) relays of every public
    ///   key in the event's "p" tags, so mentions and replies reach their recipients. It falls back
    ///   to the whole pool when nothing resolves.
    /// - A fetch, count, or subscription goes to the WRITE relays of the filters' authors. It falls
    ///   back to the whole pool when a filter names no authors, when any author has no known relay
    ///   list, or when nothing could be connected, so no author is silently dropped.
    case outbox
}
