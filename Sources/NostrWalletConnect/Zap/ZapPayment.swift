import Foundation

public import NostrClient
public import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The outcome of paying a zap through a wallet connection.
public struct ZapResult: Sendable, Hashable {
    /// The BOLT-11 invoice that was paid.
    public let invoice: String
    /// The payment preimage returned by the wallet, proving the invoice was paid.
    public let preimage: String
    /// The routing fees paid in millisatoshis, if the wallet reported them.
    public let feesPaid: Int64?

    public init(invoice: String, preimage: String, feesPaid: Int64?) {
        self.invoice = invoice
        self.preimage = preimage
        self.feesPaid = feesPaid
    }
}

extension WalletConnection {
    /// Completes a NIP-57 zap end to end: fetches the Lightning invoice from the recipient's LNURL
    /// endpoint and pays it through this wallet connection.
    ///
    /// This closes the gap the `NostrClient` zap flow leaves open. Build and sign the zap request
    /// (kind 9734) with `EventSigner.signZapRequest(...)` and resolve the recipient's
    /// `LNURLPayResponse` first, then call this to fetch and pay the invoice in one step.
    ///
    /// To confirm the recipient's LNURL provider published a matching kind-9735 zap receipt,
    /// subscribe to the zap request's relays with `NostrClient` and validate it with
    /// `ZapReceipt(event:)?.validate(lnurlProviderPubkey:expectedAmountMillisats:)` — the receipt is
    /// published to those relays, not to the wallet's NWC relay.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    ///
    /// - Parameters:
    ///   - lnurlPay: The recipient's resolved LNURL-pay response.
    ///   - amountMillisats: The amount to zap, in millisatoshis. Must be within the endpoint's
    ///     `minSendable...maxSendable` range.
    ///   - zapRequest: The signed kind-9734 zap request.
    ///   - lnurl: The recipient's bech32 `lnurl`, forwarded to the callback when provided.
    ///   - urlSession: The URL session for the LNURL request (defaults to `.shared`).
    /// - Returns: The paid invoice, its preimage, and the fees paid.
    /// - Throws: `LNURLPayResponse.InvoiceError` if the invoice can't be fetched (e.g. the amount
    ///   is out of range — surfaced before any wallet request is sent), or ``WalletConnectError`` if
    ///   the payment fails.
    public func payZap(
        lnurlPay: LNURLPayResponse,
        amountMillisats: Int64,
        zapRequest: Event,
        lnurl: String? = nil,
        urlSession: URLSession = .shared
    ) async throws -> ZapResult {
        let invoice = try await lnurlPay.fetchInvoice(
            amountMillisats: amountMillisats,
            zapRequest: zapRequest,
            lnurl: lnurl,
            urlSession: urlSession)
        let payment = try await payInvoice(invoice)
        return ZapResult(invoice: invoice, preimage: payment.preimage, feesPaid: payment.feesPaid)
    }
}
