@testable import NostrClient

/// Case accessors so a test can `#require` the payload it expects from
/// ``DirectMessageParser/open(_:)`` or ``NostrMessaging/open(_:)``.
extension DirectMessagePayload {
    var message: DirectMessage? {
        guard case .message(let message) = self else { return nil }
        return message
    }

    var reaction: DirectMessageReaction? {
        guard case .reaction(let reaction) = self else { return nil }
        return reaction
    }

    var file: DirectMessageFile? {
        guard case .file(let file) = self else { return nil }
        return file
    }
}
