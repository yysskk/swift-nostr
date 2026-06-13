import Foundation

/// The JSON body of a NIP-47 response event (kind 23195):
/// `{"result_type": ..., "error": {...}|null, "result": {...}|null}`.
///
/// Decoded from the decrypted response content by ``WalletConnection``.
struct WalletConnectResponse<Result: Decodable>: Decodable {
    let resultType: String
    let error: WalletConnectResponseError?
    let result: Result?

    enum CodingKeys: String, CodingKey {
        case resultType = "result_type"
        case error
        case result
    }
}

/// The `error` object of a NIP-47 response.
struct WalletConnectResponseError: Decodable, Sendable, Equatable {
    let code: String
    let message: String
}

// MARK: - Results

/// The result of `pay_invoice`.
public struct PayInvoiceResult: Codable, Sendable, Hashable {
    /// The payment preimage proving the invoice was paid.
    public let preimage: String
    /// The fees paid in millisatoshis, if reported.
    public let feesPaid: Int64?

    enum CodingKeys: String, CodingKey {
        case preimage
        case feesPaid = "fees_paid"
    }

    public init(preimage: String, feesPaid: Int64? = nil) {
        self.preimage = preimage
        self.feesPaid = feesPaid
    }
}

/// The result of `pay_keysend`.
public struct PayKeysendResult: Codable, Sendable, Hashable {
    /// The payment preimage.
    public let preimage: String
    /// The fees paid in millisatoshis, if reported.
    public let feesPaid: Int64?

    enum CodingKeys: String, CodingKey {
        case preimage
        case feesPaid = "fees_paid"
    }

    public init(preimage: String, feesPaid: Int64? = nil) {
        self.preimage = preimage
        self.feesPaid = feesPaid
    }
}

/// The result of `get_balance`.
public struct GetBalanceResult: Codable, Sendable, Hashable {
    /// The balance in millisatoshis.
    public let balance: Int64

    public init(balance: Int64) {
        self.balance = balance
    }
}

/// The result of `get_info`.
public struct GetInfoResult: Codable, Sendable, Hashable {
    /// The node alias.
    public let alias: String?
    /// The node color (hex).
    public let color: String?
    /// The node public key (hex).
    public let pubkey: String?
    /// The network, e.g. `"mainnet"`.
    public let network: String?
    /// The current block height.
    public let blockHeight: Int64?
    /// The current block hash (hex).
    public let blockHash: String?
    /// The methods this wallet supports.
    public let methods: [String]
    /// The notification types this wallet emits.
    public let notifications: [String]?

    enum CodingKeys: String, CodingKey {
        case alias
        case color
        case pubkey
        case network
        case blockHeight = "block_height"
        case blockHash = "block_hash"
        case methods
        case notifications
    }

    public init(
        alias: String? = nil, color: String? = nil, pubkey: String? = nil, network: String? = nil,
        blockHeight: Int64? = nil, blockHash: String? = nil, methods: [String] = [],
        notifications: [String]? = nil
    ) {
        self.alias = alias
        self.color = color
        self.pubkey = pubkey
        self.network = network
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.methods = methods
        self.notifications = notifications
    }

    // Custom decoding so `methods` defaults to empty rather than throwing for wallets that omit it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        pubkey = try container.decodeIfPresent(String.self, forKey: .pubkey)
        network = try container.decodeIfPresent(String.self, forKey: .network)
        blockHeight = try container.decodeIfPresent(Int64.self, forKey: .blockHeight)
        blockHash = try container.decodeIfPresent(String.self, forKey: .blockHash)
        methods = try container.decodeIfPresent([String].self, forKey: .methods) ?? []
        notifications = try container.decodeIfPresent([String].self, forKey: .notifications)
    }
}

/// The result of `list_transactions`.
public struct ListTransactionsResult: Codable, Sendable, Hashable {
    /// The matching transactions, newest first.
    public let transactions: [WalletConnectTransaction]

    public init(transactions: [WalletConnectTransaction]) {
        self.transactions = transactions
    }
}

/// The result of `make_invoice`: a freshly created invoice transaction.
public typealias MakeInvoiceResult = WalletConnectTransaction

/// The result of `lookup_invoice`: the matching invoice transaction.
public typealias LookupInvoiceResult = WalletConnectTransaction

/// The per-invoice result of `multi_pay_invoice` (one response event per invoice).
public typealias MultiPayInvoiceItemResult = PayInvoiceResult

/// The per-keysend result of `multi_pay_keysend` (one response event per keysend).
public typealias MultiPayKeysendItemResult = PayKeysendResult
