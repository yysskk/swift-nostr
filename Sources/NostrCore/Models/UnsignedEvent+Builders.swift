import Foundation

// Builders for the NIP-defined events this package signs.
//
// Each takes the author's public key rather than a signer, so the local ``EventSigner``
// conveniences and the ``NostrSigning``-based client helpers build the identical event and
// differ only in how it is signed.
extension UnsignedEvent {
    /// A text note (kind 1).
    package static func textNote(pubkey: String, content: String, tags: [Tag]) -> UnsignedEvent {
        UnsignedEvent(pubkey: pubkey, kind: .textNote, tags: tags, content: content)
    }

    /// A reaction to `event` (kind 7).
    package static func reaction(pubkey: String, to event: Event, content: String) -> UnsignedEvent {
        UnsignedEvent(
            pubkey: pubkey,
            kind: .reaction,
            tags: [.event(event.id), .pubkey(event.pubkey)],
            content: content
        )
    }

    /// A repost of `event` (kind 6). The reposted event is embedded in the content and
    /// referenced by an `e` tag recording `relayURL`.
    package static func repost(pubkey: String, of event: Event, relayURL: String?) throws -> UnsignedEvent {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eventJson = try encoder.encode(event)

        return UnsignedEvent(
            pubkey: pubkey,
            kind: .repost,
            tags: [.event(event.id, relayURL: relayURL), .pubkey(event.pubkey)],
            content: String(decoding: eventJson, as: UTF8.self)
        )
    }

    /// A deletion request for `eventIds` (kind 5).
    package static func deletion(pubkey: String, eventIds: [String], reason: String) -> UnsignedEvent {
        UnsignedEvent(
            pubkey: pubkey,
            kind: .eventDeletion,
            tags: eventIds.map { Tag.event($0) },
            content: reason
        )
    }

    /// A client-authentication event answering a relay's AUTH challenge (kind 22242, NIP-42).
    package static func clientAuthentication(pubkey: String, relayURL: URL, challenge: String) -> UnsignedEvent {
        UnsignedEvent(
            pubkey: pubkey,
            kind: .clientAuthentication,
            tags: [.relay(relayURL.absoluteString), .challenge(challenge)],
            content: ""
        )
    }
}
