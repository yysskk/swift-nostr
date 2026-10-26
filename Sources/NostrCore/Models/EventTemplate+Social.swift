import Foundation

// MARK: - Notes, Reactions, Reposts, and Deletions
extension EventTemplate {
    /// A text note (kind 1).
    /// https://github.com/nostr-protocol/nips/blob/master/01.md
    /// - Parameters:
    ///   - content: The note's text.
    ///   - tags: Tags to attach to the note.
    /// - Returns: The template for the note.
    public static func textNote(_ content: String, tags: [Tag] = []) -> EventTemplate {
        EventTemplate(kind: .textNote, tags: tags, content: content)
    }

    /// A reaction to `event` (kind 7), referencing the event and its author.
    /// https://github.com/nostr-protocol/nips/blob/master/25.md
    /// - Parameters:
    ///   - event: The event being reacted to.
    ///   - content: The reaction: `"+"` for a like, `"-"` for a dislike, or an emoji.
    /// - Returns: The template for the reaction.
    public static func reaction(to event: Event, content: String = "+") -> EventTemplate {
        EventTemplate(kind: .reaction, tags: [.event(event.id), .publicKey(event.publicKey)], content: content)
    }

    /// A repost of `event` (kind 6).
    /// https://github.com/nostr-protocol/nips/blob/master/18.md
    /// - Parameters:
    ///   - event: The event being reposted; it is embedded in the content and referenced by an `e` tag.
    ///   - relayURL: The relay where the reposted event can be found, recorded in the `e` tag.
    /// - Returns: The template for the repost.
    /// - Throws: `EncodingError` if `event` cannot be encoded as JSON.
    public static func repost(of event: Event, relayURL: RelayURL? = nil) throws -> EventTemplate {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let eventJSON = try encoder.encode(event)

        return EventTemplate(
            kind: .repost,
            tags: [.event(event.id, relayURL: relayURL), .publicKey(event.publicKey)],
            content: String(decoding: eventJSON, as: UTF8.self)
        )
    }

    /// A request to delete the events with `eventIDs` (kind 5), one `e` tag each.
    ///
    /// Relays honour the request only for events authored by the same public key.
    /// https://github.com/nostr-protocol/nips/blob/master/09.md
    /// - Parameters:
    ///   - eventIDs: The ids of the events to delete.
    ///   - reason: Why the events are deleted (the event content).
    /// - Returns: The template for the deletion request.
    public static func deletion(of eventIDs: [EventID], reason: String = "") -> EventTemplate {
        EventTemplate(kind: .eventDeletion, tags: eventIDs.map { Tag.event($0) }, content: reason)
    }
}
