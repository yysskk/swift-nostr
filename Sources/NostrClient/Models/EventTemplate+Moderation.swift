import NostrCore

// MARK: - Reports (NIP-56)
extension EventTemplate {
    /// A report of `publicKey` (kind 1984); the report type rides on the `p` tag.
    /// https://github.com/nostr-protocol/nips/blob/master/56.md
    /// - Parameters:
    ///   - publicKey: The reported user.
    ///   - type: The reason category.
    ///   - reason: Additional detail (the event content).
    /// - Returns: The template for the report.
    public static func report(_ publicKey: PublicKey, type: ReportType, reason: String = "") -> EventTemplate {
        EventTemplate(
            kind: .report,
            tags: [Tag(name: .publicKey, values: [publicKey.hex, type.rawValue])],
            content: reason
        )
    }

    /// A report of `event` and its author (kind 1984); the report type rides on the `e` tag, and a
    /// bare `p` tag names the author.
    /// https://github.com/nostr-protocol/nips/blob/master/56.md
    /// - Parameters:
    ///   - event: The reported event.
    ///   - type: The reason category.
    ///   - reason: Additional detail (the event content).
    /// - Returns: The template for the report.
    public static func report(_ event: Event, type: ReportType, reason: String = "") -> EventTemplate {
        EventTemplate(
            kind: .report,
            tags: [Tag(name: .event, values: [event.id.hex, type.rawValue]), .publicKey(event.publicKey)],
            content: reason
        )
    }
}
