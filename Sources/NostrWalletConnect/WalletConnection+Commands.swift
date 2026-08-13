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
    ///
    /// Give each invoice an `id` to have its response matched back to it: NIP-47 correlates a
    /// response by the item's `id` when one was supplied, and otherwise by the payment hash, which
    /// this package cannot derive from an invoice. A response that cannot be tied to a requested
    /// invoice is reported in ``MultiPayResults/unmatched`` rather than dropped.
    /// - Parameter invoices: The invoices to pay.
    /// - Returns: One outcome per invoice, in the order requested, plus any responses that could
    ///   not be tied back. Invoices with no response — on timeout, say — are ``MultiPayOutcome/noResponse``.
    public func multiPayInvoice(
        _ invoices: [MultiPayInvoiceParams.Invoice]
    ) async throws -> MultiPayResults<MultiPayInvoiceItemResult> {
        // Nothing to wait for, and a waiter no response can satisfy would sit out the whole timeout.
        guard !invoices.isEmpty else { return MultiPayResults(outcomes: []) }

        let parts = try await performRequest(
            method: .multiPayInvoice,
            params: MultiPayInvoiceParams(invoices: invoices),
            expectedResponses: invoices.count,
            partialOnTimeout: true)
        return mapItems(parts, identifiers: invoices.map(\.id), as: MultiPayInvoiceItemResult.self)
    }

    /// Sends a spontaneous (keysend) payment (`pay_keysend`).
    /// - Returns: The payment preimage and fees paid.
    public func payKeysend(_ params: PayKeysendParams) async throws -> PayKeysendResult {
        let content = try await performSingle(method: .payKeysend, params: params)
        return try decodeResult(content, as: PayKeysendResult.self)
    }

    /// Sends several keysend payments in one request (`multi_pay_keysend`).
    ///
    /// Give each keysend an `id` to have its response matched back to it; see
    /// ``multiPayInvoice(_:)`` for why.
    /// - Returns: One outcome per keysend, in the order requested, plus any responses that could
    ///   not be tied back.
    public func multiPayKeysend(
        _ keysends: [MultiPayKeysendParams.Keysend]
    ) async throws -> MultiPayResults<MultiPayKeysendItemResult> {
        guard !keysends.isEmpty else { return MultiPayResults(outcomes: []) }

        let parts = try await performRequest(
            method: .multiPayKeysend,
            params: MultiPayKeysendParams(keysends: keysends),
            expectedResponses: keysends.count,
            partialOnTimeout: true)
        return mapItems(parts, identifiers: keysends.map(\.id), as: MultiPayKeysendItemResult.self)
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

    /// Lines each response part of a `multi_pay_*` reply up with the item it answers.
    ///
    /// A response is matched to the item whose `id` its `d` tag names, each item taking at most one
    /// — a second response under the same tag has no item left to claim and goes to `unmatched`
    /// rather than overwriting the first, which is what a dictionary keyed on the tag did.
    private func mapItems<Item: Decodable & Sendable>(
        _ parts: [ResponsePart], identifiers: [String?], as _: Item.Type
    ) -> MultiPayResults<Item> {
        var outcomes = [MultiPayOutcome<Item>](repeating: .noResponse, count: identifiers.count)
        var unmatched: [UnmatchedMultiPayResponse<Item>] = []

        // Only items given an `id` can be addressed by a `d` tag; the rest stay unclaimable, and
        // their responses are reported as unmatched rather than guessed at by arrival order.
        var indexByIdentifier: [String: [Int]] = [:]
        for (index, identifier) in identifiers.enumerated() {
            guard let identifier else { continue }
            indexByIdentifier[identifier, default: []].append(index)
        }

        for part in parts {
            let result: Result<Item, WalletConnectError>
            do {
                result = .success(try decodeResult(part.content, as: Item.self))
            } catch let error as WalletConnectError {
                result = .failure(error)
            } catch {
                result = .failure(.responseDecodingFailed)
            }

            guard let dTag = part.dTag, var candidates = indexByIdentifier[dTag],
                let index = candidates.first
            else {
                unmatched.append(UnmatchedMultiPayResponse(dTag: part.dTag, result: result))
                continue
            }
            candidates.removeFirst()
            indexByIdentifier[dTag] = candidates.isEmpty ? nil : candidates
            outcomes[index] = .answered(result)
        }

        return MultiPayResults(outcomes: outcomes, unmatched: unmatched)
    }
}
