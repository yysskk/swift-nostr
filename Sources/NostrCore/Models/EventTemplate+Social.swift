import Foundation

// MARK: - Notes, Replies, Reactions, Reposts, and Deletions
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

    /// A text note (kind 1) replying to `event`, threaded with NIP-10 marked `e` tags and a `p` tag
    /// for the replied-to author.
    /// https://github.com/nostr-protocol/nips/blob/master/10.md
    /// - Parameters:
    ///   - event: The event being replied to; its thread root and author are carried over. A
    ///     relay hint on a root in NIP-10's positional form is carried over only when it is a
    ///     valid relay URL.
    ///   - content: The reply's text.
    ///   - relayURL: The relay where the replied-to event can be found, recorded in the
    ///     NIP-10 `e` tag.
    /// - Returns: The template for the reply.
    public static func reply(to event: Event, content: String, relayURL: RelayURL? = nil) -> EventTemplate {
        var tags: [Tag] = []

        // Carry over the thread root (NIP-10). The marker lives at a fixed position —
        // ["e", id, relay, marker] — so it is read there rather than searched for anywhere in
        // the tag: a relay hint or public key that happens to read "root" is not a marker.
        let parentEventTags = event.tags(named: .event)
        let markedRoot = parentEventTags.first {
            $0.values.count >= 3 && $0.values[2] == Tag.EventMarker.root.rawValue
        }

        // NIP-10's deprecated positional form carries no markers, and there the first "e" tag
        // is the root. Without this the parent looked rootless and the reply started a second
        // thread alongside the one it was answering.
        let positionalRoot =
            parentEventTags.allSatisfy { $0.values.count < 3 } ? parentEventTags.first : nil

        if let markedRoot {
            tags.append(markedRoot)
            tags.append(.event(event.id, relayURL: relayURL, marker: .reply))
        } else if let positionalRoot, let rootID = positionalRoot.primaryValue.flatMap(EventID.init) {
            // Re-emitted with an explicit "root" marker rather than copied through. Appending
            // the unmarked tag verbatim would leave a mixed set — one marked "reply", one with
            // no marker — which marked-scheme readers take to mean a mention, losing the very
            // thread this recovery exists to preserve.
            // The hint is the parent author's third-party content: kept only when it is a
            // valid relay URL.
            let hint = positionalRoot.values.count >= 2 ? RelayURL(positionalRoot.values[1]) : nil
            tags.append(.event(rootID, relayURL: hint, marker: .root))
            tags.append(.event(event.id, relayURL: relayURL, marker: .reply))
        } else {
            // The parent starts the thread, so it is the root.
            tags.append(.event(event.id, relayURL: relayURL, marker: .root))
        }

        // Mention the author being replied to.
        tags.append(.publicKey(event.publicKey))

        return .textNote(content, tags: tags)
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
    public static func repost(of event: Event, relayURL: RelayURL? = nil) -> EventTemplate {
        EventTemplate(
            kind: .repost,
            tags: [.event(event.id, relayURL: relayURL), .publicKey(event.publicKey)],
            content: String(decoding: event.jsonData, as: UTF8.self)
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
