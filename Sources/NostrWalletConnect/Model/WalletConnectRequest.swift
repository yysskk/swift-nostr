import Foundation
import NostrCore

/// A NIP-47 command answered by a single response.
///
/// A conforming value is the request's `params` object, sent under ``method``; the `result` of the
/// wallet's reply decodes into ``Response``. ``WalletConnection/send(_:)`` sends any conforming
/// request, so a command outside the built-in set — a wallet extension or a later NIP-47 revision —
/// needs only a pair of types:
///
/// ```swift
/// struct GetBudgetRequest: WalletConnectRequest {
///     typealias Response = GetBudgetResult
///     static let method = WalletConnectMethod(rawValue: "get_budget")
/// }
///
/// struct GetBudgetResult: Decodable, Sendable {
///     let usedBudget: Int64
///     let totalBudget: Int64?
///
///     enum CodingKeys: String, CodingKey {
///         case usedBudget = "used_budget"
///         case totalBudget = "total_budget"
///     }
/// }
///
/// let budget = try await connection.send(GetBudgetRequest())
/// ```
///
/// `multi_pay_invoice` and `multi_pay_keysend` draw one response per item, so they are sent with
/// ``WalletConnection/multiPayInvoice(_:)`` and ``WalletConnection/multiPayKeysend(_:)`` instead.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public protocol WalletConnectRequest: Encodable, Sendable {
    /// The type the response's `result` decodes into.
    associatedtype Response: Decodable & Sendable

    /// The command this request invokes.
    static var method: WalletConnectMethod { get }
}

/// The JSON body of a NIP-47 request event (kind 23194): `{"method": ..., "params": {...}}`.
///
/// Encoded, encrypted, and placed in the request event's content by ``WalletConnection``.
struct RequestEnvelope<Params: Encodable>: Encodable {
    let method: WalletConnectMethod
    let params: Params
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

// MARK: - Requests

/// A `pay_invoice` request: pays a BOLT-11 invoice.
public struct PayInvoiceRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = PayInvoiceResult

    public static let method: WalletConnectMethod = .payInvoice

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

/// A single invoice within a `multi_pay_invoice` request.
public struct MultiPayInvoiceItem: Codable, Sendable, Hashable {
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

/// The `params` of a `multi_pay_invoice` request.
struct MultiPayInvoiceParams: Encodable, Sendable {
    let invoices: [MultiPayInvoiceItem]
}

/// A `pay_keysend` request: sends a spontaneous payment to a Lightning node.
public struct PayKeysendRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = PayKeysendResult

    public static let method: WalletConnectMethod = .payKeysend

    /// The amount to send in millisatoshis.
    public let amount: Int64
    /// The recipient Lightning node's hex public key: a node key, not a Nostr `PublicKey`.
    public let nodePublicKey: String
    /// An optional preimage for the payment.
    public let preimage: String?
    /// Optional TLV records to include with the payment.
    public let tlvRecords: [TLVRecord]?

    enum CodingKeys: String, CodingKey {
        case amount
        case nodePublicKey = "pubkey"
        case preimage
        case tlvRecords = "tlv_records"
    }

    public init(amount: Int64, nodePublicKey: String, preimage: String? = nil, tlvRecords: [TLVRecord]? = nil) {
        self.amount = amount
        self.nodePublicKey = nodePublicKey
        self.preimage = preimage
        self.tlvRecords = tlvRecords
    }
}

/// A single keysend payment within a `multi_pay_keysend` request.
public struct MultiPayKeysendItem: Codable, Sendable, Hashable {
    /// An optional client-chosen id used to correlate this keysend's response.
    public let id: String?
    /// The recipient Lightning node's hex public key: a node key, not a Nostr `PublicKey`.
    public let nodePublicKey: String
    /// The amount to send in millisatoshis.
    public let amount: Int64
    /// An optional preimage for the payment.
    public let preimage: String?
    /// Optional TLV records to include with the payment.
    public let tlvRecords: [TLVRecord]?

    enum CodingKeys: String, CodingKey {
        case id
        case nodePublicKey = "pubkey"
        case amount
        case preimage
        case tlvRecords = "tlv_records"
    }

    public init(
        id: String? = nil, nodePublicKey: String, amount: Int64, preimage: String? = nil,
        tlvRecords: [TLVRecord]? = nil
    ) {
        self.id = id
        self.nodePublicKey = nodePublicKey
        self.amount = amount
        self.preimage = preimage
        self.tlvRecords = tlvRecords
    }
}

/// The `params` of a `multi_pay_keysend` request.
struct MultiPayKeysendParams: Encodable, Sendable {
    let keysends: [MultiPayKeysendItem]
}

/// A `make_invoice` request: creates an invoice.
public struct MakeInvoiceRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = MakeInvoiceResult

    public static let method: WalletConnectMethod = .makeInvoice

    /// The invoice amount in millisatoshis.
    public let amount: Int64
    /// An optional invoice description.
    public let description: String?
    /// An optional invoice description hash.
    public let descriptionHash: String?
    /// How long after creation the invoice expires, if set.
    ///
    /// The wire carries whole seconds, so the sub-second part is truncated toward zero when
    /// encoding: an expiry never comes out longer than the one asked for.
    public let expiry: Duration?
    /// Optional application-defined metadata.
    public let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case amount
        case description
        case descriptionHash = "description_hash"
        case expiry
        case metadata
    }

    /// Creates a `make_invoice` request.
    /// - Parameters:
    ///   - amount: The invoice amount in millisatoshis.
    ///   - description: An optional invoice description.
    ///   - descriptionHash: An optional invoice description hash.
    ///   - expiry: How long after creation the invoice expires; sent as whole seconds.
    ///   - metadata: Optional application-defined metadata.
    public init(
        amount: Int64, description: String? = nil, descriptionHash: String? = nil,
        expiry: Duration? = nil, metadata: [String: JSONValue]? = nil
    ) {
        self.amount = amount
        self.description = description
        self.descriptionHash = descriptionHash
        self.expiry = expiry
        self.metadata = metadata
    }

    /// Decodes the request, reading `expiry` as an integer number of seconds.
    /// - Throws: `DecodingError` if a field has the wrong type.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            amount: try container.decode(Int64.self, forKey: .amount),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            descriptionHash: try container.decodeIfPresent(String.self, forKey: .descriptionHash),
            expiry: try container.decodeIfPresent(Int64.self, forKey: .expiry).map(Duration.seconds),
            metadata: try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata))
    }

    /// Encodes the request, writing `expiry` as whole seconds truncated toward zero.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(amount, forKey: .amount)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encodeIfPresent(descriptionHash, forKey: .descriptionHash)
        try container.encodeIfPresent(expiry?.wholeSeconds, forKey: .expiry)
        try container.encodeIfPresent(metadata, forKey: .metadata)
    }
}

/// A `lookup_invoice` request: looks up an invoice.
///
/// Construct one with ``paymentHash(_:)`` or ``invoice(_:)`` — the type guarantees exactly one
/// lookup key is set, so an invalid empty request cannot be expressed.
public struct LookupInvoiceRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = LookupInvoiceResult

    public static let method: WalletConnectMethod = .lookupInvoice

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
    public static func paymentHash(_ paymentHash: String) -> LookupInvoiceRequest {
        LookupInvoiceRequest(paymentHash: paymentHash, invoice: nil)
    }

    /// Looks up an invoice by its BOLT-11 string.
    public static func invoice(_ invoice: String) -> LookupInvoiceRequest {
        LookupInvoiceRequest(paymentHash: nil, invoice: invoice)
    }
}

/// A NIP-47 transaction direction.
public enum TransactionType: String, Codable, Sendable, Hashable {
    case incoming
    case outgoing
}

/// A `list_transactions` request: lists transactions.
public struct ListTransactionsRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = ListTransactionsResult

    public static let method: WalletConnectMethod = .listTransactions

    /// Only include transactions created at or after this time.
    public let from: Timestamp?
    /// Only include transactions created at or before this time.
    public let until: Timestamp?
    /// The maximum number of transactions to return.
    public let limit: Int?
    /// The number of transactions to skip.
    public let offset: Int?
    /// Whether to include unpaid transactions.
    public let unpaid: Bool?
    /// Filter by transaction direction.
    public let type: TransactionType?

    /// Creates a `list_transactions` request; nil leaves a criterion to the wallet's default.
    ///
    /// `from` and `until` encode as integer Unix seconds.
    public init(
        from: Timestamp? = nil, until: Timestamp? = nil, limit: Int? = nil, offset: Int? = nil,
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

/// A `get_balance` request: reads the wallet balance. Its `params` are empty (`{}`).
public struct GetBalanceRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = GetBalanceResult

    public static let method: WalletConnectMethod = .getBalance

    public init() {}
}

/// A `get_info` request: reads the wallet's Lightning node information. Its `params` are empty
/// (`{}`).
public struct GetInfoRequest: WalletConnectRequest, Codable, Hashable {
    public typealias Response = GetInfoResult

    public static let method: WalletConnectMethod = .getInfo

    public init() {}
}
