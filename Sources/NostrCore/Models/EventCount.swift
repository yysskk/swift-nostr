/// The result of a NIP-45 COUNT request from one relay.
/// https://github.com/nostr-protocol/nips/blob/master/45.md
public struct EventCount: Sendable, Hashable {
    /// The number of events the relay reports matching the filters.
    public let value: Int

    /// Whether the relay flagged the count as approximate.
    public let isApproximate: Bool

    /// Creates an event count.
    /// - Parameters:
    ///   - value: The number of events the relay reports matching the filters.
    ///   - isApproximate: Whether the relay flagged the count as approximate.
    public init(value: Int, isApproximate: Bool = false) {
        self.value = value
        self.isApproximate = isApproximate
    }
}
