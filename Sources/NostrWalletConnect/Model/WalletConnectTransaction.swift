import Foundation
import NostrCore

/// A NIP-47 transaction object, returned by `make_invoice`, `lookup_invoice`, and
/// `list_transactions`.
///
/// Fields beyond ``type`` and ``amount`` are optional because wallet services populate them
/// differently for incoming vs outgoing and pending vs settled transactions.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public struct WalletConnectTransaction: Codable, Sendable, Hashable {
    /// The direction, including directions this package has no constant for.
    public let type: TransactionType
    /// The settlement state, including states this package has no constant for.
    public let state: TransactionState?
    /// The BOLT-11 invoice, when applicable.
    public let invoice: String?
    /// The invoice description.
    public let description: String?
    /// The invoice description hash.
    public let descriptionHash: String?
    /// The payment preimage, when settled.
    public let preimage: String?
    /// The payment hash.
    public let paymentHash: String?
    /// The amount in millisatoshis.
    public let amount: Int64
    /// The fees paid in millisatoshis.
    public let feesPaid: Int64?
    /// When the transaction was created (`created_at`).
    public let createdAt: Timestamp?
    /// When the invoice expires (`expires_at`).
    public let expiresAt: Timestamp?
    /// When the transaction settled (`settled_at`), if it has.
    public let settledAt: Timestamp?
    /// Application-defined metadata.
    public let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case type
        case state
        case invoice
        case description
        case descriptionHash = "description_hash"
        case preimage
        case paymentHash = "payment_hash"
        case amount
        case feesPaid = "fees_paid"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case settledAt = "settled_at"
        case metadata
    }

    /// Creates a transaction from its fields; every time encodes as integer Unix seconds.
    public init(
        type: TransactionType, state: TransactionState? = nil, invoice: String? = nil, description: String? = nil,
        descriptionHash: String? = nil, preimage: String? = nil, paymentHash: String? = nil,
        amount: Int64, feesPaid: Int64? = nil, createdAt: Timestamp? = nil,
        expiresAt: Timestamp? = nil, settledAt: Timestamp? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.type = type
        self.state = state
        self.invoice = invoice
        self.description = description
        self.descriptionHash = descriptionHash
        self.preimage = preimage
        self.paymentHash = paymentHash
        self.amount = amount
        self.feesPaid = feesPaid
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.settledAt = settledAt
        self.metadata = metadata
    }
}

/// The settlement state of a NIP-47 transaction.
///
/// The set is open-ended: the states NIP-47 defines are available as static constants, and any other
/// state a wallet reports is kept as is. The value encodes to and from JSON as a bare string.
public struct TransactionState: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// The wire state name.
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

    /// Not yet paid or settled (`pending`).
    public static let pending = TransactionState(rawValue: "pending")
    /// Paid and settled (`settled`).
    public static let settled = TransactionState(rawValue: "settled")
    /// An invoice that expired unpaid (`expired`).
    public static let expired = TransactionState(rawValue: "expired")
    /// A payment that failed (`failed`).
    public static let failed = TransactionState(rawValue: "failed")
}
