import Foundation

/// A decrypted NIP-17 gift-wrap payload: a direct message or a reaction to one.
///
/// A single gift-wrap stream (kind 1059 addressed to the user) carries both messages
/// (kind 14) and reactions (kind 7). Returned by ``NostrClient/directMessagePayloads(limit:)``
/// and ``NostrClient/parseDirectMessagePayload(_:)`` so callers can handle both in one place.
public enum DirectMessagePayload: Sendable, Hashable {
    /// A private direct message (kind 14).
    case message(DirectMessage)
    /// A reaction to a direct message (kind 7).
    case reaction(DirectMessageReaction)
}
