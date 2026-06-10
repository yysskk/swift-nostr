import Foundation

/// Relay usage marker for a NIP-65 relay entry.
/// An empty marker on the wire is interpreted as `.readWrite`.
public enum RelayUsage: String, Codable, Hashable, Sendable, CaseIterable {
    case read
    case write
    case readWrite

    /// Whether this usage permits reading (subscribing) from the relay.
    public var canRead: Bool {
        self == .read || self == .readWrite
    }

    /// Whether this usage permits writing (publishing) to the relay.
    public var canWrite: Bool {
        self == .write || self == .readWrite
    }
}
