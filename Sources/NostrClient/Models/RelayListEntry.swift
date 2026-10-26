import Foundation
import NostrCore

/// A single relay entry in a NIP-65 Relay List Metadata event.
/// https://github.com/nostr-protocol/nips/blob/master/65.md
public struct RelayListEntry: Codable, Hashable, Sendable {
    /// The relay URL (e.g. "wss://relay.example.com").
    public let url: RelayURL

    /// How the author uses this relay.
    public let usage: RelayUsage

    /// Creates an entry for the relay at `url`.
    public init(url: RelayURL, usage: RelayUsage = .readWrite) {
        self.url = url
        self.usage = usage
    }

    /// The "r" tag for a kind 10002 event, with the URL in canonical form.
    public var tag: Tag {
        switch usage {
        case .readWrite:
            return Tag(name: "r", values: [url.description])
        case .read:
            return Tag(name: "r", values: [url.description, "read"])
        case .write:
            return Tag(name: "r", values: [url.description, "write"])
        }
    }

    /// Creates an entry from an "r" tag.
    /// Returns nil for non-"r" tags and for tags whose URL is not a valid relay URL. An unknown
    /// marker is treated leniently as read+write.
    public init?(tag: Tag) {
        guard tag.name == "r", let url = tag.primaryValue.flatMap(RelayURL.init) else {
            return nil
        }

        let marker = tag.values.count > 1 ? tag.values[1] : ""
        let usage: RelayUsage
        switch marker {
        case "read":
            usage = .read
        case "write":
            usage = .write
        default:
            // Empty marker means both; unknown markers are interpreted leniently as both.
            usage = .readWrite
        }

        self.init(url: url, usage: usage)
    }
}
