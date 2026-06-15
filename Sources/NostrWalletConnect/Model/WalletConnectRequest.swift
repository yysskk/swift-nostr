import Foundation

/// The JSON body of a NIP-47 request event (kind 23194): `{"method": ..., "params": {...}}`.
///
/// Encoded, encrypted, and placed in the request event's content by ``WalletConnection``.
struct WalletConnectRequest<Params: Encodable>: Encodable {
    let method: String
    let params: Params

    init(method: WalletConnectMethod, params: Params) {
        self.method = method.rawValue
        self.params = params
    }
}

/// A single TLV record for a keysend payment.
public struct TLVRecord: Codable, Sendable, Hashable {
    /// The TLV type (record key).
    public let type: UInt64
    /// The record value, hex-encoded.
    public let value: String

    public init(type: UInt64, value: String) {
        self.type = type
        self.value = value
    }
}

// MARK: - Parameters

/// Parameters for `pay_invoice`.
public struct PayInvoiceParams: Codable, Sendable, Hashable {
    /// The BOLT-11 invoice to pay.
    public let invoice: String
    /// The amount to pay in millisatoshis, for amountless invoices or to override the invoice amount.
    public let amount: Int64?
    /// Optional application-defined metadata.
    public let metadata: [String: JSONValue]?

    public init(invoice: String, amount: Int64? = nil, metadata: [String: JSONValue]? = nil) {
        self.invoice = invoice
        self.amount = amount
        self.metadata = metadata
    }
}

/// Parameters for `multi_pay_invoice`.
public struct MultiPayInvoiceParams: Codable, Sendable, Hashable {
    /// A single invoice within a multi-payment.
    public struct Invoice: Codable, Sendable, Hashable {
        /// An optional client-chosen id used to correlate this invoice's response. Defaults to the
        /// payment hash when omitted.
        public let id: String?
        /// The BOLT-11 invoice to pay.
        public let invoice: String
        /// The amount to pay in millisatoshis, if not implied by the invoice.
        public let amount: Int64?

        public init(id: String? = nil, invoice: String, amount: Int64? = nil) {
            self.id = id
            self.invoice = invoice
            self.amount = amount
        }
    }

    /// The invoices to pay.
    public let invoices: [Invoice]

    public init(invoices: [Invoice]) {
        self.invoices = invoices
    }
}

/// Parameters for `pay_keysend`.
public struct PayKeysendParams: Codable, Sendable, Hashable {
    /// The amount to send in millisatoshis.
    public let amount: Int64
    /// The recipient node's public key (hex).
    public let pubkey: String
    /// An optional preimage for the payment.
    public let preimage: String?
    /// Optional TLV records to include with the payment.
    public let tlvRecords: [TLVRecord]?

    enum CodingKeys: String, CodingKey {
        case amount
        case pubkey
        case preimage
        case tlvRecords = "tlv_records"
    }

    public init(amount: Int64, pubkey: String, preimage: String? = nil, tlvRecords: [TLVRecord]? = nil) {
        self.amount = amount
        self.pubkey = pubkey
        self.preimage = preimage
        self.tlvRecords = tlvRecords
    }
}

/// Parameters for `multi_pay_keysend`.
public struct MultiPayKeysendParams: Codable, Sendable, Hashable {
    /// A single keysend within a multi-payment.
    public struct Keysend: Codable, Sendable, Hashable {
        /// An optional client-chosen id used to correlate this keysend's response.
        public let id: String?
        /// The recipient node's public key (hex).
        public let pubkey: String
        /// The amount to send in millisatoshis.
        public let amount: Int64
        /// An optional preimage for the payment.
        public let preimage: String?
        /// Optional TLV records to include with the payment.
        public let tlvRecords: [TLVRecord]?

        enum CodingKeys: String, CodingKey {
            case id
            case pubkey
            case amount
            case preimage
            case tlvRecords = "tlv_records"
        }

        public init(
            id: String? = nil, pubkey: String, amount: Int64, preimage: String? = nil,
            tlvRecords: [TLVRecord]? = nil
        ) {
            self.id = id
            self.pubkey = pubkey
            self.amount = amount
            self.preimage = preimage
            self.tlvRecords = tlvRecords
        }
    }

    /// The keysend payments to send.
    public let keysends: [Keysend]

    public init(keysends: [Keysend]) {
        self.keysends = keysends
    }
}

/// Parameters for `make_invoice`.
public struct MakeInvoiceParams: Codable, Sendable, Hashable {
    /// The invoice amount in millisatoshis.
    public let amount: Int64
    /// An optional invoice description.
    public let description: String?
    /// An optional invoice description hash.
    public let descriptionHash: String?
    /// An optional expiry in seconds from creation.
    public let expiry: Int64?
    /// Optional application-defined metadata.
    public let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case amount
        case description
        case descriptionHash = "description_hash"
        case expiry
        case metadata
    }

    public init(
        amount: Int64, description: String? = nil, descriptionHash: String? = nil,
        expiry: Int64? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.amount = amount
        self.description = description
        self.descriptionHash = descriptionHash
        self.expiry = expiry
        self.metadata = metadata
    }
}

/// Parameters for `lookup_invoice`.
///
/// Construct one with ``paymentHash(_:)`` or ``invoice(_:)`` — the type guarantees exactly one
/// lookup key is set, so an invalid empty request cannot be expressed.
public struct LookupInvoiceParams: Codable, Sendable, Hashable {
    /// The payment hash to look up, if looking up by payment hash.
    public let paymentHash: String?
    /// The BOLT-11 invoice to look up, if looking up by invoice.
    public let invoice: String?

    enum CodingKeys: String, CodingKey {
        case paymentHash = "payment_hash"
        case invoice
    }

    private init(paymentHash: String?, invoice: String?) {
        self.paymentHash = paymentHash
        self.invoice = invoice
    }

    /// Looks up an invoice by its payment hash.
    public static func paymentHash(_ paymentHash: String) -> LookupInvoiceParams {
        LookupInvoiceParams(paymentHash: paymentHash, invoice: nil)
    }

    /// Looks up an invoice by its BOLT-11 string.
    public static func invoice(_ invoice: String) -> LookupInvoiceParams {
        LookupInvoiceParams(paymentHash: nil, invoice: invoice)
    }
}

/// A NIP-47 transaction direction.
public enum TransactionType: String, Codable, Sendable, Hashable {
    case incoming
    case outgoing
}

/// Parameters for `list_transactions`.
public struct ListTransactionsParams: Codable, Sendable, Hashable {
    /// Only include transactions at or after this Unix timestamp (seconds).
    public let from: Int64?
    /// Only include transactions at or before this Unix timestamp (seconds).
    public let until: Int64?
    /// The maximum number of transactions to return.
    public let limit: Int?
    /// The number of transactions to skip.
    public let offset: Int?
    /// Whether to include unpaid transactions.
    public let unpaid: Bool?
    /// Filter by transaction direction.
    public let type: TransactionType?

    public init(
        from: Int64? = nil, until: Int64? = nil, limit: Int? = nil, offset: Int? = nil,
        unpaid: Bool? = nil, type: TransactionType? = nil
    ) {
        self.from = from
        self.until = until
        self.limit = limit
        self.offset = offset
        self.unpaid = unpaid
        self.type = type
    }
}

/// Empty parameters, used by `get_balance` and `get_info`.
public struct EmptyParams: Codable, Sendable, Hashable {
    public init() {}
}
