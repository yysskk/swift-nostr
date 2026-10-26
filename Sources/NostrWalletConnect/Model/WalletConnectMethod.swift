/// A NIP-47 wallet command.
///
/// The raw value is the `method` string used in a request and echoed back as the `result_type` in a
/// response. The set is open-ended: the commands this package implements are available as static
/// constants, and any method a wallet advertises or a future NIP-47 revision defines can be
/// represented with ``init(rawValue:)``. The value encodes to and from JSON as a bare string.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public struct WalletConnectMethod: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// The wire method name.
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

    /// Pays a BOLT-11 invoice (`pay_invoice`).
    public static let payInvoice = WalletConnectMethod(rawValue: "pay_invoice")
    /// Pays several BOLT-11 invoices in one request (`multi_pay_invoice`).
    public static let multiPayInvoice = WalletConnectMethod(rawValue: "multi_pay_invoice")
    /// Sends a keysend payment (`pay_keysend`).
    public static let payKeysend = WalletConnectMethod(rawValue: "pay_keysend")
    /// Sends several keysend payments in one request (`multi_pay_keysend`).
    public static let multiPayKeysend = WalletConnectMethod(rawValue: "multi_pay_keysend")
    /// Creates an invoice (`make_invoice`).
    public static let makeInvoice = WalletConnectMethod(rawValue: "make_invoice")
    /// Looks up an invoice (`lookup_invoice`).
    public static let lookupInvoice = WalletConnectMethod(rawValue: "lookup_invoice")
    /// Lists transactions (`list_transactions`).
    public static let listTransactions = WalletConnectMethod(rawValue: "list_transactions")
    /// Reads the wallet balance (`get_balance`).
    public static let getBalance = WalletConnectMethod(rawValue: "get_balance")
    /// Reads the wallet's node information (`get_info`).
    public static let getInfo = WalletConnectMethod(rawValue: "get_info")
}
