import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

/// A `multi_pay_*` request draws one response per item, and the caller has to be able to say which
/// invoice each result belongs to. Counting raw events and keying results by a `d` tag lost that:
/// one response arriving over two relays completed the request early, and two results sharing a tag
/// silently overwrote each other.
@Suite("Multi-Pay Response Matching Tests")
struct MultiPayMatchingTests {
    private func makeConnection(timeout: TimeInterval = 2) throws -> (
        connection: WalletConnection, transport: FakeWalletConnectTransport, client: KeyPair, wallet: KeyPair
    ) {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client),
            transport: transport,
            config: .init(requestTimeout: timeout, preferredEncryption: .nip44))
        return (connection, transport, client, wallet)
    }

    /// A connection URI may list several relays, and this path merges them without deduplicating —
    /// that only happens in `RelayPool`, which the wallet transport bypasses. The same response
    /// event then arrived twice, completed the request, and left the other invoice's answer with
    /// nowhere to go: the caller was told an invoice had no result while it may have been paid.
    @Test("a response delivered twice is counted once")
    func duplicateResponseIsCountedOnce() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 2)

        async let results = connection.multiPayInvoice([
            .init(id: "a", invoice: "lnbc1"),
            .init(id: "b", invoice: "lnbc2"),
        ])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        let responseForA = try NWCFixtures.response(
            resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"pa"}}"#,
            requestID: request.id, client: client, wallet: wallet, dTag: "a")

        // The identical event over two relays.
        await transport.emit(responseForA)
        await transport.emit(responseForA)
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"pb"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "b"))

        let mapped = try await results

        #expect(mapped.outcomes[0].value?.preimage == "pa")
        #expect(mapped.outcomes[1].value?.preimage == "pb")
        #expect(mapped.unmatched.isEmpty)
    }

    /// Keyed by `d` tag, a second result under the same tag replaced the first and the caller saw
    /// fewer results than invoices, with nothing saying which had been lost.
    @Test("a duplicate d tag is reported rather than overwriting a result")
    func duplicateDTagIsReported() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 0.4)

        async let results = connection.multiPayInvoice([
            .init(id: "a", invoice: "lnbc1"),
            .init(id: "b", invoice: "lnbc2"),
        ])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        // Two distinct responses that both name "a" — different events, same tag.
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"first"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "a"))
        await transport.emit(
            Event(
                id: "resp-second-a", pubkey: wallet.publicKeyHex, createdAt: 0,
                kind: .walletConnectResponse,
                tags: [["e", request.id], ["p", client.publicKeyHex], ["d", "a"]],
                content: try NWCFixtures.encrypt(
                    #"{"result_type":"multi_pay_invoice","result":{"preimage":"second"}}"#,
                    to: client, from: wallet, scheme: .nip44),
                sig: ""))

        let mapped = try await results

        #expect(mapped.outcomes[0].value?.preimage == "first")
        #expect(mapped.indicesWithoutResponse == [1])
        // The second result is surfaced instead of silently replacing the first.
        #expect(mapped.unmatched.count == 1)
        #expect(mapped.unmatched.first?.dTag == "a")
        #expect(try mapped.unmatched.first?.result.get().preimage == "second")
    }

    /// A response naming a `d` tag no invoice asked for still describes a payment that happened.
    @Test("a response for an unknown item is surfaced as unmatched")
    func unknownDTagIsUnmatched() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 0.4)

        async let results = connection.multiPayInvoice([.init(id: "a", invoice: "lnbc1")])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"stray"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "unexpected"))

        let mapped = try await results

        #expect(mapped.indicesWithoutResponse == [0])
        #expect(mapped.unmatched.first?.dTag == "unexpected")
        #expect(try mapped.unmatched.first?.result.get().preimage == "stray")
    }

    /// An empty list has nothing to wait for, and a waiter no response can satisfy sat out the
    /// whole timeout before returning nothing.
    @Test("an empty multi-pay returns immediately")
    func emptyMultiPayReturnsImmediately() async throws {
        let (connection, _, _, _) = try makeConnection(timeout: 30)

        let clock = ContinuousClock()
        let start = clock.now
        let invoiceResults = try await connection.multiPayInvoice([])
        let keysendResults = try await connection.multiPayKeysend([])
        let elapsed = clock.now - start

        #expect(invoiceResults.outcomes.isEmpty)
        #expect(keysendResults.outcomes.isEmpty)
        // Anything well under the 30-second timeout separates "returned at once" from "waited".
        #expect(elapsed < .seconds(1))
    }

    /// A reply carrying another command's `result_type` answers a different request; folding it in
    /// let a body of the wrong shape satisfy this one whenever it happened to decode.
    @Test("a response for another command is not folded into a multi-pay")
    func mismatchedResultTypeIsRejected() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 0.4)

        async let results = connection.multiPayInvoice([
            .init(id: "a", invoice: "lnbc1"),
            .init(id: "b", invoice: "lnbc2"),
        ])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"get_balance","result":{"preimage":"wrong"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "a"))

        let mapped = try await results

        #expect(mapped.indicesWithoutResponse == [0, 1])
        #expect(mapped.unmatched.isEmpty)
    }

    /// For a single-response command there is nothing left to wait for, so the mismatch is reported
    /// rather than left to time out — and it says what actually went wrong.
    @Test("a single-response command reports a mismatched result_type")
    func singleResponseMismatchedResultTypeIsReported() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 2)

        let payment = Task { try await connection.payInvoice("lnbc1") }

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"get_balance","result":{"balance":100}}"#,
                requestID: request.id, client: client, wallet: wallet))

        await #expect(
            throws: WalletConnectError.unexpectedResultType(
                expected: "pay_invoice", received: "get_balance")
        ) {
            _ = try await payment.value
        }
    }

    @Test("the matching result_type is accepted")
    func matchingResultTypeIsAccepted() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 2)

        async let results = connection.multiPayInvoice([.init(id: "a", invoice: "lnbc1")])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"ok"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "a"))

        #expect(try await results.outcomes[0].value?.preimage == "ok")
    }
}
