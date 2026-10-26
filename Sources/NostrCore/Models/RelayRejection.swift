import Foundation

/// A relay's refusal of a request: an `OK` `false` answering an `EVENT` or `AUTH`, or a `CLOSED`
/// ending a `COUNT` (NIP-01).
///
/// The relay's status string is split into its machine-readable ``prefix`` and the human-readable
/// ``message``, so callers can react to *why* the relay said no without parsing strings:
///
/// ```swift
/// do {
///     try await connection.publish(event)
/// } catch let rejection as RelayRejection where rejection.prefix == .pow {
///     // Mine the event to the relay's difficulty and publish again.
/// }
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/01.md
public struct RelayRejection: Swift.Error, LocalizedError, Sendable, Hashable {
    /// The machine-readable prefix of the status string (e.g. ``RelayResponsePrefix/pow``), or
    /// `nil` when the relay sent none.
    public let prefix: RelayResponsePrefix?

    /// The human-readable part of the status string, without the prefix and the whitespace after
    /// its colon; the whole status string when there is no prefix. May be empty.
    public let message: String

    /// Creates a rejection from its parts.
    /// - Parameters:
    ///   - prefix: The machine-readable prefix, or `nil` for none.
    ///   - message: The human-readable part, without the prefix.
    public init(prefix: RelayResponsePrefix?, message: String) {
        self.prefix = prefix
        self.message = message
    }

    /// Creates a rejection from the raw status string of an `OK` or `CLOSED` message.
    ///
    /// The prefix is parsed as ``RelayResponsePrefix/init(message:)`` parses it, so ordinary prose
    /// that happens to contain a colon keeps the whole string as its ``message``:
    ///
    /// ```swift
    /// RelayRejection(status: "pow: difficulty 20 required")  // prefix .pow, message "difficulty 20 required"
    /// RelayRejection(status: "try again: later")             // prefix nil, message "try again: later"
    /// ```
    public init(status: String) {
        guard let prefix = RelayResponsePrefix(message: status),
            let colonIndex = status.firstIndex(of: ":")
        else {
            self.init(prefix: nil, message: status)
            return
        }
        let remainder = status[status.index(after: colonIndex)...].drop(while: \.isWhitespace)
        self.init(prefix: prefix, message: String(remainder))
    }

    /// The prefix and message recombined into a status string, e.g. `"pow: difficulty 20 required"`.
    var status: String {
        switch (prefix, message.isEmpty) {
        case (let prefix?, false): "\(prefix): \(message)"
        case (let prefix?, true): prefix.rawValue
        case (nil, _): message
        }
    }

    public var errorDescription: String? {
        status.isEmpty ? "The relay rejected the request" : "The relay rejected the request: \(status)"
    }
}
