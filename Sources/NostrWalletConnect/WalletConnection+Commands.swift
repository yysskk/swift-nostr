/// The typed NIP-47 commands.
extension WalletConnection {
    /// Pays a BOLT-11 invoice (`pay_invoice`).
    /// - Parameters:
    ///   - invoice: The BOLT-11 invoice to pay.
    ///   - amount: An optional amount in millisatoshis, for amountless invoices.
    /// - Returns: The payment preimage and fees paid.
    public func payInvoice(_ invoice: String, amount: Int64? = nil) async throws -> PayInvoiceResult {
        let content = try await performSingle(
            method: .payInvoice, params: PayInvoiceParams(invoice: invoice, amount: amount))
        return try decodeResult(content, as: PayInvoiceResult.self)
    }

    /// Pays several invoices in one request (`multi_pay_invoice`). The wallet replies with one
    /// response per invoice.
    /// - Parameter invoices: The invoices to pay.
    /// - Returns: Per-invoice results keyed by the response's `d` tag (the invoice `id` if provided,
    ///   otherwise the payment hash). Invoices with no response (e.g. on timeout) are absent.
    public func multiPayInvoice(
        _ invoices: [MultiPayInvoiceParams.Invoice]
    ) async throws -> [String: Result<MultiPayInvoiceItemResult, WalletConnectError>] {
        let parts = try await performRequest(
            method: .multiPayInvoice,
            params: MultiPayInvoiceParams(invoices: invoices),
            expectedResponses: invoices.count,
            partialOnTimeout: true)
        return mapItems(parts, as: MultiPayInvoiceItemResult.self)
    }

    /// Sends a spontaneous (keysend) payment (`pay_keysend`).
    /// - Returns: The payment preimage and fees paid.
    public func payKeysend(_ params: PayKeysendParams) async throws -> PayKeysendResult {
        let content = try await performSingle(method: .payKeysend, params: params)
        return try decodeResult(content, as: PayKeysendResult.self)
    }

    /// Sends several keysend payments in one request (`multi_pay_keysend`).
    /// - Returns: Per-keysend results keyed by the response's `d` tag.
    public func multiPayKeysend(
        _ keysends: [MultiPayKeysendParams.Keysend]
    ) async throws -> [String: Result<MultiPayKeysendItemResult, WalletConnectError>] {
        let parts = try await performRequest(
            method: .multiPayKeysend,
            params: MultiPayKeysendParams(keysends: keysends),
            expectedResponses: keysends.count,
            partialOnTimeout: true)
        return mapItems(parts, as: MultiPayKeysendItemResult.self)
    }

    /// Creates an invoice (`make_invoice`).
    public func makeInvoice(_ params: MakeInvoiceParams) async throws -> MakeInvoiceResult {
        let content = try await performSingle(method: .makeInvoice, params: params)
        return try decodeResult(content, as: MakeInvoiceResult.self)
    }

    /// Looks up an invoice by payment hash or BOLT-11 string (`lookup_invoice`).
    public func lookupInvoice(_ params: LookupInvoiceParams) async throws -> LookupInvoiceResult {
        let content = try await performSingle(method: .lookupInvoice, params: params)
        return try decodeResult(content, as: LookupInvoiceResult.self)
    }

    /// Lists transactions (`list_transactions`).
    /// - Returns: The matching transactions, newest first.
    public func listTransactions(
        _ params: ListTransactionsParams = ListTransactionsParams()
    ) async throws -> [WalletConnectTransaction] {
        let content = try await performSingle(method: .listTransactions, params: params)
        return try decodeResult(content, as: ListTransactionsResult.self).transactions
    }

    /// Returns the wallet balance in millisatoshis (`get_balance`).
    public func getBalance() async throws -> GetBalanceResult {
        let content = try await performSingle(method: .getBalance, params: EmptyParams())
        return try decodeResult(content, as: GetBalanceResult.self)
    }

    /// Returns the wallet node info (`get_info`).
    public func getInfo() async throws -> GetInfoResult {
        let content = try await performSingle(method: .getInfo, params: EmptyParams())
        return try decodeResult(content, as: GetInfoResult.self)
    }

    /// Decodes each response part of a `multi_pay_*` reply, keyed by its `d` tag (falling back to the
    /// part's index when absent).
    private func mapItems<Item: Decodable>(
        _ parts: [ResponsePart], as _: Item.Type
    ) -> [String: Result<Item, WalletConnectError>] {
        var results: [String: Result<Item, WalletConnectError>] = [:]
        for (index, part) in parts.enumerated() {
            let key = part.dTag ?? String(index)
            do {
                results[key] = .success(try decodeResult(part.content, as: Item.self))
            } catch let error as WalletConnectError {
                results[key] = .failure(error)
            } catch {
                results[key] = .failure(.responseDecodingFailed)
            }
        }
        return results
    }
}
