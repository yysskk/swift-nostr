/// A NIP-47 wallet command.
///
/// The raw value is the `method` string used in a request and echoed back as the `result_type` in a
/// response.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public enum WalletConnectMethod: String, Codable, Sendable, Hashable, CaseIterable {
    case payInvoice = "pay_invoice"
    case multiPayInvoice = "multi_pay_invoice"
    case payKeysend = "pay_keysend"
    case multiPayKeysend = "multi_pay_keysend"
    case makeInvoice = "make_invoice"
    case lookupInvoice = "lookup_invoice"
    case listTransactions = "list_transactions"
    case getBalance = "get_balance"
    case getInfo = "get_info"
}
