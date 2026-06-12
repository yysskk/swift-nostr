import Foundation

/// A machine-readable prefix of an `OK` or `CLOSED` relay message (NIP-01).
///
/// When a relay denies an event or ends a subscription, the human-readable
/// status string starts with a standardized single-word prefix followed by
/// `": "`, e.g. `"auth-required: we only accept events from registered users"`.
/// The prefix tells clients *why* the request was denied so they can react
/// programmatically — for example by authenticating (NIP-42) and retrying.
///
/// Prefixes are open-ended like event kinds, so this is a `RawRepresentable`
/// struct rather than a closed enum: the prefixes standardized in NIP-01 and
/// NIP-42 are available as static constants, and prefixes introduced by future
/// NIPs or custom relays are preserved as-is.
///
/// ```swift
/// if RelayResponsePrefix(message: closedMessage) == .authRequired {
///     // Authenticate and re-subscribe.
/// }
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct RelayResponsePrefix: RawRepresentable, Sendable, Hashable, CustomStringConvertible {
    /// The prefix as it appears on the wire, e.g. `"auth-required"`.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String {
        rawValue
    }

    // MARK: Standardized Prefixes (NIP-01)

    /// The relay already has this event.
    public static let duplicate = RelayResponsePrefix(rawValue: "duplicate")

    /// The event does not meet the relay's proof-of-work requirement (NIP-13).
    public static let pow = RelayResponsePrefix(rawValue: "pow")

    /// The relay refuses to serve this client or pubkey.
    public static let blocked = RelayResponsePrefix(rawValue: "blocked")

    /// The client is sending too fast and should slow down before retrying.
    public static let rateLimited = RelayResponsePrefix(rawValue: "rate-limited")

    /// The event or request is malformed or fails validation.
    public static let invalid = RelayResponsePrefix(rawValue: "invalid")

    /// The operation is not allowed for this pubkey. Standardized in NIP-01;
    /// NIP-42 uses it for operations that remain forbidden even after the
    /// client has authenticated.
    public static let restricted = RelayResponsePrefix(rawValue: "restricted")

    /// The relay has muted this pubkey or content.
    public static let mute = RelayResponsePrefix(rawValue: "mute")

    /// A failure that fits no other prefix.
    public static let error = RelayResponsePrefix(rawValue: "error")

    // MARK: NIP-42

    /// The operation requires the client to authenticate first (NIP-42).
    public static let authRequired = RelayResponsePrefix(rawValue: "auth-required")
}

// MARK: - Parsing
extension RelayResponsePrefix {
    /// Extracts the machine-readable prefix from an `OK` or `CLOSED` status
    /// string, or returns `nil` when the string carries none.
    ///
    /// Per NIP-01 the prefix is a single word terminated by the first `":"`,
    /// so a message whose leading segment is empty or contains whitespace —
    /// i.e. ordinary prose that happens to contain a colon — does not parse
    /// as a prefix.
    ///
    /// ```swift
    /// RelayResponsePrefix(message: "duplicate: already have this event")  // .duplicate
    /// RelayResponsePrefix(message: "all good")                            // nil
    /// ```
    public init?(message: String) {
        guard let colonIndex = message.firstIndex(of: ":") else { return nil }
        let candidate = message[message.startIndex..<colonIndex]
        guard !candidate.isEmpty, !candidate.contains(where: \.isWhitespace) else { return nil }
        self.init(rawValue: String(candidate))
    }
}

// MARK: - String Literal
extension RelayResponsePrefix: ExpressibleByStringLiteral {
    /// Builds a prefix from a string literal: `let prefix: RelayResponsePrefix = "auth-required"`.
    public init(stringLiteral value: String) {
        self.init(rawValue: value)
    }
}

// MARK: - RelayMessage Convenience
extension RelayMessage {
    /// The machine-readable prefix of this message's status string, for the
    /// `ok` and `closed` messages that carry one (NIP-01). `nil` for other
    /// message types and for status strings without a prefix.
    public var responsePrefix: RelayResponsePrefix? {
        switch self {
        case .ok(_, _, let message), .closed(_, let message):
            RelayResponsePrefix(message: message)
        default:
            nil
        }
    }
}
