import Foundation

/// A NIP-47 wallet notification (kind 23196 / 23197).
///
/// The decrypted content is `{"notification_type": ..., "notification": {...}}`. For the standard
/// `payment_received` / `payment_sent` notifications the payload is a transaction, exposed via
/// ``transaction``; ``raw`` always holds the full payload for other notification types.
public struct WalletConnectNotification: Sendable, Hashable {
    /// The notification type, including types this package has no constant for.
    public let type: WalletConnectNotificationType

    /// The payload decoded as a transaction, when it is one.
    public let transaction: WalletConnectTransaction?

    /// The full notification payload.
    public let raw: [String: JSONValue]

    public init(type: WalletConnectNotificationType, transaction: WalletConnectTransaction?, raw: [String: JSONValue]) {
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
        let notificationType: WalletConnectNotificationType
        let notification: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case notificationType = "notification_type"
            case notification
        }
    }
}

/// A NIP-47 notification type.
///
/// The raw value is the `notification_type` of a notification and a token of a wallet's
/// `notifications` list. The set is open-ended: the types this package documents are available as
/// static constants, and any type a wallet emits can be represented with ``init(rawValue:)``. The
/// value encodes to and from JSON as a bare string.
public struct WalletConnectNotificationType: RawRepresentable, Codable, Sendable, Hashable,
    CustomStringConvertible
{
    /// The wire notification type.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }

    /// The wallet received a payment (`payment_received`).
    public static let paymentReceived = WalletConnectNotificationType(rawValue: "payment_received")
    /// The wallet sent a payment (`payment_sent`).
    public static let paymentSent = WalletConnectNotificationType(rawValue: "payment_sent")
}
