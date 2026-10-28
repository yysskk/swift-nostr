/// The typed NIP-47 commands.
///
/// Each single-response command takes its request's fields as labeled parameters, with the same
/// labels and defaults as the request's initializer, and sends the built ``WalletConnectRequest``
/// through ``WalletConnection/send(_:)``. Call ``WalletConnection/send(_:)`` directly to send a
/// request value you already hold, or any other request.
extension WalletConnection {
    /// Pays a BOLT-11 invoice (`pay_invoice`).
    /// - Parameters:
    ///   - invoice: The BOLT-11 invoice to pay.
    ///   - amount: An optional amount in millisatoshis, for amountless invoices or to override the
    ///     invoice amount.
    ///   - metadata: Optional application-defined metadata.
    /// - Returns: The payment preimage and fees paid.
    /// - Throws: What ``send(_:)`` throws.
    public func payInvoice(
        _ invoice: String, amount: Int64? = nil, metadata: [String: JSONValue]? = nil
    ) async throws(WalletConnectError) -> PaymentResult {
        let request = PayInvoiceRequest(invoice: invoice, amount: amount, metadata: metadata)
        return try await send(request)
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
    /// - Throws: What ``send(_:)`` throws for the request as a whole. A timeout returns the outcomes
    ///   so far instead, and an item the wallet failed is reported in its outcome.
    public func multiPayInvoice(
        _ invoices: [MultiPayInvoiceItem]
    ) async throws(WalletConnectError) -> MultiPayResults {
        // Nothing to wait for, and a waiter no response can satisfy would sit out the whole timeout.
        guard !invoices.isEmpty else { return MultiPayResults(outcomes: []) }

        let parts = try await performRequest(
            method: .multiPayInvoice,
            params: MultiPayInvoiceParams(invoices: invoices),
            expectedResponses: invoices.count,
            partialOnTimeout: true)
        return mapItems(parts, identifiers: invoices.map(\.id))
    }

    /// Sends a spontaneous (keysend) payment (`pay_keysend`).
    /// - Parameters:
    ///   - amount: The amount to send in millisatoshis.
    ///   - nodePublicKey: The recipient Lightning node's hex public key: a node key, not a Nostr
    ///     `PublicKey`.
    ///   - preimage: An optional preimage for the payment.
    ///   - tlvRecords: Optional TLV records to include with the payment.
    /// - Returns: The payment preimage and fees paid.
    /// - Throws: What ``send(_:)`` throws.
    public func payKeysend(
        amount: Int64, nodePublicKey: String, preimage: String? = nil, tlvRecords: [TLVRecord]? = nil
    ) async throws(WalletConnectError) -> PaymentResult {
        let request = PayKeysendRequest(
            amount: amount, nodePublicKey: nodePublicKey, preimage: preimage, tlvRecords: tlvRecords)
        return try await send(request)
    }

    /// Sends several keysend payments in one request (`multi_pay_keysend`).
    ///
    /// Give each keysend an `id` to have its response matched back to it; see
    /// ``multiPayInvoice(_:)`` for why.
    /// - Returns: One outcome per keysend, in the order requested, plus any responses that could
    ///   not be tied back.
    /// - Throws: What ``multiPayInvoice(_:)`` throws.
    public func multiPayKeysend(
        _ keysends: [MultiPayKeysendItem]
    ) async throws(WalletConnectError) -> MultiPayResults {
        guard !keysends.isEmpty else { return MultiPayResults(outcomes: []) }

        let parts = try await performRequest(
            method: .multiPayKeysend,
            params: MultiPayKeysendParams(keysends: keysends),
            expectedResponses: keysends.count,
            partialOnTimeout: true)
        return mapItems(parts, identifiers: keysends.map(\.id))
    }

    /// Creates an invoice (`make_invoice`).
    /// - Parameters:
    ///   - amount: The invoice amount in millisatoshis.
    ///   - description: An optional invoice description.
    ///   - descriptionHash: An optional invoice description hash.
    ///   - expiry: How long after creation the invoice expires; sent as whole seconds, truncated.
    ///   - metadata: Optional application-defined metadata.
    /// - Returns: The created invoice transaction.
    /// - Throws: What ``send(_:)`` throws.
    public func makeInvoice(
        amount: Int64, description: String? = nil, descriptionHash: String? = nil, expiry: Duration? = nil,
        metadata: [String: JSONValue]? = nil
    ) async throws(WalletConnectError) -> MakeInvoiceResult {
        let request = MakeInvoiceRequest(
            amount: amount, description: description, descriptionHash: descriptionHash, expiry: expiry,
            metadata: metadata)
        return try await send(request)
    }

    /// Looks up an invoice by payment hash or BOLT-11 string (`lookup_invoice`).
    ///
    /// ```swift
    /// let invoice = try await connection.lookupInvoice(.paymentHash(hash))
    /// ```
    /// - Parameter key: The payment hash or BOLT-11 invoice to look up.
    /// - Returns: The matching invoice transaction.
    /// - Throws: What ``send(_:)`` throws.
    public func lookupInvoice(
        _ key: LookupInvoiceRequest.Key
    ) async throws(WalletConnectError) -> LookupInvoiceResult {
        try await send(LookupInvoiceRequest(key))
    }

    /// Lists transactions (`list_transactions`). A `nil` criterion is left to the wallet's default.
    /// - Parameters:
    ///   - from: Only include transactions created at or after this time.
    ///   - until: Only include transactions created at or before this time.
    ///   - limit: The maximum number of transactions to return.
    ///   - offset: The number of transactions to skip.
    ///   - unpaid: Whether to include unpaid transactions.
    ///   - type: Only include transactions in this direction.
    /// - Returns: The matching transactions, newest first.
    /// - Throws: What ``send(_:)`` throws.
    public func listTransactions(
        from: Timestamp? = nil, until: Timestamp? = nil, limit: Int? = nil, offset: Int? = nil,
        unpaid: Bool? = nil, type: TransactionType? = nil
    ) async throws(WalletConnectError) -> [WalletConnectTransaction] {
        let request = ListTransactionsRequest(
            from: from, until: until, limit: limit, offset: offset, unpaid: unpaid, type: type)
        return try await send(request).transactions
    }

    /// Fetches the wallet balance in millisatoshis (`get_balance`).
    /// - Throws: What ``send(_:)`` throws.
    public func fetchBalance() async throws(WalletConnectError) -> GetBalanceResult {
        try await send(GetBalanceRequest())
    }

    /// Fetches the wallet's Lightning node info (`get_info`).
    ///
    /// For the capabilities the wallet advertises in its info event, see ``fetchCapabilities()``.
    /// - Throws: What ``send(_:)`` throws.
    public func fetchNodeInfo() async throws(WalletConnectError) -> GetInfoResult {
        try await send(GetInfoRequest())
    }

    /// Lines each response part of a `multi_pay_*` reply up with the item it answers.
    ///
    /// A response is matched to the item whose `id` its `d` tag names, each item taking at most one
    /// — a second response under the same tag has no item left to claim and goes to `unmatched`
    /// rather than overwriting the first, which is what a dictionary keyed on the tag did.
    private func mapItems(_ parts: [ResponsePart], identifiers: [String?]) -> MultiPayResults {
        var outcomes = [MultiPayOutcome](repeating: .noResponse, count: identifiers.count)
        var unmatched: [UnmatchedMultiPayResponse] = []

        // Only items given an `id` can be addressed by a `d` tag; the rest stay unclaimable, and
        // their responses are reported as unmatched rather than guessed at by arrival order.
        var indexByIdentifier: [String: [Int]] = [:]
        for (index, identifier) in identifiers.enumerated() {
            guard let identifier else { continue }
            indexByIdentifier[identifier, default: []].append(index)
        }

        for part in parts {
            let result: Result<PaymentResult, WalletConnectError>
            do throws(WalletConnectError) {
                result = .success(try decodeResult(part.content, as: PaymentResult.self))
            } catch {
                result = .failure(error)
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
