import Foundation

/// A single Nostr event tag (NIP-01). See ``Event/Tag``.
///
/// Where the bare name is ambiguous (e.g. test targets importing
/// swift-testing, which declares its own `Tag`), use `Event.Tag`.
public typealias Tag = Event.Tag

extension Event {
    /// A single Nostr event tag (NIP-01): a non-empty string array whose first
    /// element is the tag name.
    ///
    /// Build tags with the typed constructors instead of hand-rolling arrays —
    /// they take care of NIP positional conventions, including the empty-string
    /// placeholders for skipped middle elements:
    ///
    /// ```swift
    /// Tag.event(noteId, marker: .reply)   // ["e", noteId, "", "reply"]
    /// Tag.pubkey(pk, petname: "alice")    // ["p", pk, "", "alice"]
    /// Tag.hashtag("nostr")                // ["t", "nostr"]
    /// ```
    ///
    /// `Tag` is also expressible as an array literal (`["t", "nostr"]`), so call
    /// sites that passed `[[String]]` literals keep compiling unchanged.
    public struct Tag: Sendable, Hashable {
        /// The tag name, e.g. "e", "p", "t", "d".
        public let name: String

        /// The elements after the name. Positional per NIP conventions;
        /// empty strings act as placeholders for skipped elements.
        public let values: [String]

        public init(name: String, values: [String] = []) {
            self.name = name
            self.values = values
        }

        /// Parses a raw NIP-01 tag array. Returns nil if the array is empty.
        public init?(rawArray: [String]) {
            guard let name = rawArray.first else { return nil }
            self.name = name
            self.values = Array(rawArray.dropFirst())
        }

        /// The raw NIP-01 representation: `[name] + values`.
        public var rawArray: [String] {
            [name] + values
        }

        /// The first value — the id, pubkey, or topic for single-value tags.
        public var primaryValue: String? {
            values.first
        }
    }
}

// MARK: - Typed Constructors
extension Tag {
    /// NIP-10 marker for "e" tags.
    public enum EventMarker: String, Sendable, Hashable {
        case root
        case reply
        case mention
    }

    /// An "e" tag referencing an event (NIP-10): `["e", id, relay, marker, pubkey]`.
    /// Skipped middle elements are padded with empty-string placeholders.
    public static func event(
        _ id: String,
        relayURL: String? = nil,
        marker: EventMarker? = nil,
        pubkey: String? = nil
    ) -> Tag {
        var values = [id]
        if let relayURL {
            values.append(relayURL)
        } else if marker != nil || pubkey != nil {
            values.append("")
        }
        if let marker {
            values.append(marker.rawValue)
        } else if pubkey != nil {
            values.append("")
        }
        if let pubkey {
            values.append(pubkey)
        }
        return Tag(name: "e", values: values)
    }

    /// A "p" tag referencing a pubkey: `["p", pubkey, relay, petname]`.
    /// Skipped middle elements are padded with empty-string placeholders.
    public static func pubkey(
        _ pubkey: String,
        relayURL: String? = nil,
        petname: String? = nil
    ) -> Tag {
        var values = [pubkey]
        if let relayURL {
            values.append(relayURL)
        } else if petname != nil {
            values.append("")
        }
        if let petname {
            values.append(petname)
        }
        return Tag(name: "p", values: values)
    }

    /// A "t" hashtag tag.
    public static func hashtag(_ topic: String) -> Tag {
        Tag(name: "t", values: [topic])
    }

    /// A "d" identifier tag (addressable events).
    public static func identifier(_ identifier: String) -> Tag {
        Tag(name: "d", values: [identifier])
    }

    /// A "subject" tag (NIP-14 / NIP-17).
    public static func subject(_ subject: String) -> Tag {
        Tag(name: "subject", values: [subject])
    }

    /// A "relay" tag carrying the URL of the relay the client is
    /// authenticating to (NIP-42).
    public static func relay(_ url: String) -> Tag {
        Tag(name: "relay", values: [url])
    }

    /// A "challenge" tag echoing the challenge string from a relay's
    /// AUTH message (NIP-42).
    public static func challenge(_ challenge: String) -> Tag {
        Tag(name: "challenge", values: [challenge])
    }

    /// An "expiration" tag marking when relays should stop serving the event (NIP-40).
    ///
    /// The value is the Unix timestamp in whole seconds; sub-second precision is dropped.
    /// After this moment a relay should no longer return the event and may delete it.
    /// https://github.com/nostr-protocol/nips/blob/master/40.md
    public static func expiration(_ date: Date) -> Tag {
        Tag(name: "expiration", values: [String(Int64(date.timeIntervalSince1970))])
    }

    /// An arbitrary raw tag. Returns nil if the array is empty.
    public static func raw(_ array: [String]) -> Tag? {
        Tag(rawArray: array)
    }
}

// MARK: - Array Literal
extension Tag: ExpressibleByArrayLiteral {
    /// Builds a tag from a string array literal: `["e", eventId]`.
    /// The literal must contain at least the tag name.
    public init(arrayLiteral elements: String...) {
        precondition(!elements.isEmpty, "A tag array literal requires at least the tag name")
        self.name = elements[0]
        self.values = Array(elements.dropFirst())
    }
}

// MARK: - Codable
extension Tag: Codable {
    /// Encodes as the bare NIP-01 JSON array, e.g. `["e","abc..."]`.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawArray)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawArray = try container.decode([String].self)
        guard let tag = Tag(rawArray: rawArray) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "A tag array must contain at least the tag name"
            )
        }
        self = tag
    }
}

// MARK: - Event Tag Accessors
extension Event {
    /// A typed view of this event's tags (malformed empty arrays are skipped).
    public var structuredTags: [Tag] {
        tags.compactMap(Tag.init(rawArray:))
    }

    /// All tags with the given name.
    public func tags(named name: String) -> [Tag] {
        structuredTags.filter { $0.name == name }
    }

    /// The first value of the first tag with the given name.
    public func firstTagValue(named name: String) -> String? {
        tags(named: name).first?.primaryValue
    }

    /// The event IDs referenced by "e" tags.
    public var referencedEventIds: [String] {
        tags.filter { $0.count >= 2 && $0[0] == "e" }.map { $0[1] }
    }

    /// The pubkeys referenced by "p" tags.
    public var referencedPubkeys: [String] {
        tags.filter { $0.count >= 2 && $0[0] == "p" }.map { $0[1] }
    }

    /// The event's NIP-40 expiration time, if it carries a valid `expiration` tag.
    ///
    /// After this time, relays should stop serving the event and may delete it.
    /// Returns nil when there is no `expiration` tag or its value is not an integer.
    public var expiration: Date? {
        guard let value = firstTagValue(named: "expiration"), let seconds = Int64(value) else {
            return nil
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Whether the event has a NIP-40 ``expiration`` at or before `date` (default: now).
    ///
    /// An event without an `expiration` tag never expires, so this returns false.
    public func isExpired(asOf date: Date = Date()) -> Bool {
        guard let expiration else { return false }
        return expiration <= date
    }
}
