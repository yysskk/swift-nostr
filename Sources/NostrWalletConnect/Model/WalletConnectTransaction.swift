import Foundation
import NostrCore

/// A NIP-47 transaction object, returned by `make_invoice`, `lookup_invoice`, and
/// `list_transactions`.
///
/// Fields beyond ``type`` and ``amount`` are optional because wallet services populate them
/// differently for incoming vs outgoing and pending vs settled transactions.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public struct WalletConnectTransaction: Codable, Sendable, Hashable {
    /// `"incoming"` or `"outgoing"`.
    public let type: String
    /// Settlement state, e.g. `"pending"`, `"settled"`, or `"failed"`.
    public let state: String?
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
        type: String, state: String? = nil, invoice: String? = nil, description: String? = nil,
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
