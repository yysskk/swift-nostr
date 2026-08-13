import Foundation
import NostrCore

/// Picks which of the events a fetch returned to believe.
///
/// A relay is free to answer a filter with whatever it likes: events by another author, of another
/// kind, under another `d` identifier, or with a signature that does not verify. A fetch that takes
/// the newest event it was handed therefore trusts the relay rather than the author — and for a
/// replaceable event, a forged copy with a far-future `created_at` wins every time, since newer
/// always displaces older. Selecting through here makes the author's signature the thing that
/// decides.
enum VerifiedEventSelection {
    /// The newest event matching the requested coordinates whose signature verifies.
    ///
    /// Ties on `created_at` are broken by the lowest id, the convention NIP-01 gives for
    /// replaceable events, so every relay in a pool resolves the same conflict the same way.
    /// - Parameters:
    ///   - events: The events a fetch returned.
    ///   - kind: The kind requested, or nil to accept any.
    ///   - author: The pubkey requested, or nil to accept any author.
    ///   - identifier: The `d` tag requested for an addressable event, or nil when the coordinates
    ///     do not include one.
    /// - Returns: The winning event, or nil when nothing survives the checks.
    static func newest(
        in events: [Event],
        kind: Event.Kind? = nil,
        author: String? = nil,
        identifier: String? = nil
    ) -> Event? {
        var newest: Event?
        for event in events {
            guard matches(event, kind: kind, author: author, identifier: identifier) else { continue }
            // Checked last: it is the expensive test, and the cheap coordinate checks have already
            // discarded most of what a misbehaving relay might send.
            guard (try? event.verify()) == true else { continue }

            if let current = newest {
                let supersedes =
                    event.createdAt > current.createdAt
                    || (event.createdAt == current.createdAt && event.id < current.id)
                guard supersedes else { continue }
            }
            newest = event
        }
        return newest
    }

    /// The event with `id`, if the fetch returned it and its signature verifies.
    ///
    /// A relay that ignores an id filter can substitute any event; without this the caller believes
    /// it holds the event it asked for.
    static func event(withID id: String, in events: [Event]) -> Event? {
        events.first { $0.id == id && (try? $0.verify()) == true }
    }

    private static func matches(
        _ event: Event,
        kind: Event.Kind?,
        author: String?,
        identifier: String?
    ) -> Bool {
        if let kind, event.kind != kind { return false }
        if let author, event.pubkey != author { return false }
        if let identifier, event.firstTagValue(named: "d") != identifier { return false }
        return true
    }
}
