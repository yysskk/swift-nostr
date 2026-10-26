import NostrCore

// MARK: - Relay Lists (NIP-65, NIP-17)
extension EventTemplate {
    /// A relay list metadata event (kind 10002): one `r` tag per relay, marked for reading,
    /// writing, or both, and an empty content.
    /// https://github.com/nostr-protocol/nips/blob/master/65.md
    /// - Parameter relayList: The author's read and write relays.
    /// - Returns: The template for the relay list.
    public static func relayListMetadata(_ relayList: RelayListMetadata) -> EventTemplate {
        EventTemplate(kind: .relayListMetadata, tags: relayList.tags)
    }

    /// A DM relay list (kind 10050) advertising where the author receives private direct
    /// messages: one `relay` tag per relay and an empty content.
    /// https://github.com/nostr-protocol/nips/blob/master/17.md
    /// - Parameter relayList: The author's DM relays.
    /// - Returns: The template for the DM relay list.
    public static func directMessageRelayList(_ relayList: DirectMessageRelayList) -> EventTemplate {
        EventTemplate(kind: .directMessageRelayList, tags: relayList.tags)
    }
}
