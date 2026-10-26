import Foundation

// MARK: - Relay Authentication (NIP-42)
extension EventTemplate {
    /// A client authentication event (kind 22242) answering a relay's AUTH challenge.
    ///
    /// The event carries the relay URL and the challenge as tags and an empty content. It is
    /// ephemeral: relays validate it during the AUTH handshake and neither store nor broadcast it.
    /// https://github.com/nostr-protocol/nips/blob/master/42.md
    /// - Parameters:
    ///   - relayURL: The URL of the relay being authenticated to.
    ///   - challenge: The challenge string received in the relay's AUTH message.
    /// - Returns: The template for the authentication event.
    public static func clientAuthentication(relayURL: RelayURL, challenge: String) -> EventTemplate {
        EventTemplate(kind: .clientAuthentication, tags: [.relay(relayURL), .challenge(challenge)])
    }
}
