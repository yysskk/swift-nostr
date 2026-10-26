import Foundation

// Builders for the NIP-defined events this package signs.
//
// Each takes the author's public key rather than a signer, so the local ``EventSigner``
// conveniences and the ``NostrSigning``-based client helpers build the identical event and
// differ only in how it is signed.
extension UnsignedEvent {
    /// A text note (kind 1).
    package static func textNote(publicKey: PublicKey, content: String, tags: [Tag]) -> UnsignedEvent {
        UnsignedEvent(publicKey: publicKey, kind: .textNote, tags: tags, content: content)
    }

    /// A reaction to `event` (kind 7).
    package static func reaction(publicKey: PublicKey, to event: Event, content: String) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey,
            kind: .reaction,
            tags: [.event(event.id), .publicKey(event.publicKey)],
            content: content
        )
    }

    /// A repost of `event` (kind 6). The reposted event is embedded in the content and
    /// referenced by an `e` tag recording `relayURL`.
    package static func repost(publicKey: PublicKey, of event: Event, relayURL: RelayURL?) throws -> UnsignedEvent {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eventJson = try encoder.encode(event)

        return UnsignedEvent(
            publicKey: publicKey,
            kind: .repost,
            tags: [.event(event.id, relayURL: relayURL), .publicKey(event.publicKey)],
            content: String(decoding: eventJson, as: UTF8.self)
        )
    }

    /// A deletion request for `eventIDs` (kind 5).
    package static func deletion(publicKey: PublicKey, eventIDs: [EventID], reason: String) -> UnsignedEvent {
        UnsignedEvent(
            publicKey: publicKey,
            kind: .eventDeletion,
            tags: eventIDs.map { Tag.event($0) },
            content: reason
        )
    }

    /// A client-authentication event answering a relay's AUTH challenge (kind 22242, NIP-42).
    package static func clientAuthentication(publicKey: PublicKey, relayURL: RelayURL, challenge: String)
        -> UnsignedEvent
    {
        UnsignedEvent(
            publicKey: publicKey,
            kind: .clientAuthentication,
            tags: [.relay(relayURL), .challenge(challenge)],
            content: ""
        )
    }
}
