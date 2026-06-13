import Foundation

/// A decrypted NIP-17 gift-wrap payload: a direct message, a reaction to one, or a file.
///
/// A single gift-wrap stream (kind 1059 addressed to the user) carries messages (kind 14),
/// reactions (kind 7), and file messages (kind 15). Returned by
/// ``NostrClient/directMessagePayloads(limit:)`` and ``NostrClient/parseDirectMessagePayload(_:)``
/// so callers can handle them in one place.
public enum DirectMessagePayload: Sendable, Hashable {
    /// A private direct message (kind 14).
    case message(DirectMessage)
    /// A reaction to a direct message (kind 7).
    case reaction(DirectMessageReaction)
    /// An encrypted file message (kind 15).
    case file(DirectMessageFile)
}
