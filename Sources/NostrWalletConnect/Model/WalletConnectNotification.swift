import Foundation

/// A NIP-47 wallet notification (kind 23196 / 23197).
///
/// The decrypted content is `{"notification_type": ..., "notification": {...}}`. For the standard
/// `payment_received` / `payment_sent` notifications the payload is a transaction, exposed via
/// ``transaction``; ``raw`` always holds the full payload for other notification types.
public struct WalletConnectNotification: Sendable, Hashable {
    /// The notification type, e.g. `"payment_received"` or `"payment_sent"`.
    public let type: String

    /// The payload decoded as a transaction, when it is one.
    public let transaction: WalletConnectTransaction?

    /// The full notification payload.
    public let raw: [String: JSONValue]

    public init(type: String, transaction: WalletConnectTransaction?, raw: [String: JSONValue]) {
        self.type = type
        self.transaction = transaction
        self.raw = raw
    }

    /// Parses a decrypted notification content string. Returns `nil` if it is not a valid envelope.
    init?(content: String) {
        guard let data = content.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else {
            return nil
        }
        self.type = envelope.notificationType
        self.raw = envelope.notification
        // Best-effort: most notifications carry a transaction payload.
        if let payload = try? JSONEncoder().encode(envelope.notification),
            let transaction = try? JSONDecoder().decode(WalletConnectTransaction.self, from: payload)
        {
            self.transaction = transaction
        } else {
            self.transaction = nil
        }
    }

    private struct Envelope: Decodable {
        let notificationType: String
        let notification: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case notificationType = "notification_type"
            case notification
        }
    }
}
