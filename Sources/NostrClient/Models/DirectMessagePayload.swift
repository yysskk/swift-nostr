import Foundation
import NostrCore

/// A decrypted NIP-17 gift-wrap payload: a direct message, a reaction to one, or a file.
///
/// A single gift-wrap stream (kind 1059 addressed to the user) carries messages (kind 14),
/// reactions (kind 7), and file messages (kind 15). Returned by
/// ``NostrMessaging/payloads(limit:)`` and ``NostrMessaging/parsePayload(_:)``
/// so callers can handle them in one place.
public enum DirectMessagePayload: Sendable, Hashable {
    /// A private direct message (kind 14).
    case message(DirectMessage)
    /// A reaction to a direct message (kind 7).
    case reaction(DirectMessageReaction)
    /// An encrypted file message (kind 15).
    case file(DirectMessageFile)
}

extension DirectMessagePayload {
    /// The kind of the rumor this payload was read from.
    var kind: Event.Kind {
        switch self {
        case .message: .privateDirectMessage
        case .reaction: .reaction
        case .file: .fileMessage
        }
    }

    /// An error reading a NIP-17 payload out of an unwrapped gift wrap.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The rumor is not the kind being read — a message (14), reaction (7), or file message
        /// (15) — or, when reading any payload, none of them (payload: the rumor's kind).
        case unexpectedKind(Event.Kind)
        /// The rumor's `p` tag is not a canonical hex public key, so it names no recipient.
        case invalidRecipient
        /// A reaction does not reference the message (`e`) and its author (`p`) by canonical hex
        /// id and key.
        case missingReactionTarget
        /// A file message's content is not an `http` or `https` URL with a host, so there is no file
        /// to download.
        case invalidFileURL
        /// A file message's `decryption-key` tag is missing or is not a base64 32-byte key.
        case invalidDecryptionKey
        /// A file message's `decryption-nonce` tag is missing or is not a base64 12-byte nonce.
        case invalidDecryptionNonce

        public var errorDescription: String? {
            switch self {
            case .unexpectedKind(let kind):
                return "Unexpected direct message kind \(kind.rawValue)"
            case .invalidRecipient:
                return "A direct message's p tag must be a hex public key"
            case .missingReactionTarget:
                return "A direct message reaction must reference a message and its author"
            case .invalidFileURL:
                return "A file message must carry the file's http or https URL"
            case .invalidDecryptionKey:
                return "A file message must carry a 32-byte decryption key"
            case .invalidDecryptionNonce:
                return "A file message must carry a 12-byte decryption nonce"
            }
        }
    }
}
