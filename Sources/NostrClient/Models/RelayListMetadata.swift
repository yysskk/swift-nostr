import Foundation
import NostrCore

/// NIP-65 Relay List Metadata (kind 10002).
/// A replaceable event where an author advertises the relays they read from and write to.
/// https://github.com/nostr-protocol/nips/blob/master/65.md
public struct RelayListMetadata: Codable, Hashable, Sendable {
    /// The relay entries, in document order.
    public let entries: [RelayListEntry]

    public init(entries: [RelayListEntry]) {
        self.entries = entries
    }

    /// URLs the author reads from (their inbox). Send a user events here so they will see them.
    public var readRelays: [String] {
        entries.filter { $0.usage.canRead }.map { $0.url }
    }

    /// URLs the author writes to (their outbox). Read a user's events from here.
    public var writeRelays: [String] {
        entries.filter { $0.usage.canWrite }.map { $0.url }
    }

    /// Converts to the full tag array for a kind 10002 event.
    public func toTags() -> [[String]] {
        entries.map { $0.toTag() }
    }

    /// Parses a relay list from a kind 10002 event. Returns nil if the event is not kind 10002.
    public init?(event: Event) {
        guard event.kind == .relayListMetadata else {
            return nil
        }
        self.init(tags: event.tags)
    }

    /// Parses a relay list from raw tags (kind-agnostic). Duplicate relay URLs are removed (first wins).
    public init(tags: [[String]]) {
        var seen = Set<String>()
        var result: [RelayListEntry] = []
        for tag in tags {
            guard let entry = RelayListEntry.fromTag(tag) else {
                continue
            }
            let key = RelayURL.normalize(entry.url)
            if seen.insert(key).inserted {
                result.append(entry)
            }
        }
        self.entries = result
    }
}

// MARK: - Relay List Metadata Helpers
extension Event {
    /// Extracts the NIP-65 relay list from a kind 10002 event.
    /// Returns nil if the event is not a relay list metadata event.
    public var relayListMetadata: RelayListMetadata? {
        RelayListMetadata(event: self)
    }

    /// Checks if this is a kind 10002 relay list metadata event.
    public var isRelayListMetadata: Bool {
        kind == .relayListMetadata
    }
}
