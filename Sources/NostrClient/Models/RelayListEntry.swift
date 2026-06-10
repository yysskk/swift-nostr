import Foundation

/// A single relay entry in a NIP-65 Relay List Metadata event.
/// https://github.com/nostr-protocol/nips/blob/master/65.md
public struct RelayListEntry: Codable, Hashable, Sendable {
    /// The relay URL (e.g. "wss://relay.example.com").
    public let url: String

    /// How the author uses this relay.
    public let usage: RelayUsage

    public init(url: String, usage: RelayUsage = .readWrite) {
        self.url = url
        self.usage = usage
    }

    /// Converts to an "r" tag array for a kind 10002 event.
    public func toTag() -> [String] {
        switch usage {
        case .readWrite:
            return ["r", url]
        case .read:
            return ["r", url, "read"]
        case .write:
            return ["r", url, "write"]
        }
    }

    /// Creates an entry from an "r" tag array.
    /// Returns nil for non-"r" or malformed tags. An unknown marker is treated leniently as read+write.
    public static func fromTag(_ tag: [String]) -> RelayListEntry? {
        guard tag.count >= 2, tag[0] == "r", !tag[1].isEmpty else {
            return nil
        }

        let url = tag[1]
        let marker = tag.count > 2 ? tag[2] : ""
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

        return RelayListEntry(url: url, usage: usage)
    }
}
