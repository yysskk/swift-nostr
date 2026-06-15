import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnection Round-Trip Tests")
struct WalletConnectionRoundTripTests {
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

    @Test("payInvoice sends a request and returns the preimage")
    func payInvoiceRoundTrip() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        async let result = connection.payInvoice("lnbc1", amount: 21000)

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        #expect(request.kind == .walletConnectRequest)
        let response = try NWCFixtures.response(
            resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"deadbeef","fees_paid":10}}"#,
            requestID: request.id, client: client, wallet: wallet)
        await transport.emit(response)

        let payment = try await result
        #expect(payment.preimage == "deadbeef")
        #expect(payment.feesPaid == 10)
    }

    @Test("the request event carries p, encryption, and expiration tags")
    func requestTags() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        async let result = connection.payInvoice("lnbc1")
        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]

        #expect(request.firstTagValue(named: "p") == wallet.publicKeyHex)
        #expect(request.firstTagValue(named: "encryption") == "nip44_v2")
        #expect(request.firstTagValue(named: "expiration") != nil)

        let response = try NWCFixtures.response(
            resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"aa"}}"#,
            requestID: request.id, client: client, wallet: wallet)
        await transport.emit(response)
        _ = try await result
    }

    @Test("concurrent commands correlate responses by the e tag")
    func concurrentCorrelation() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        async let balance = connection.getBalance()
        async let payment = connection.payInvoice("lnbc1")

        let requests = try await NWCFixtures.waitForSentEvents(transport, count: 2)
        for request in requests {
            let json = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
            if json.contains("get_balance") {
                await transport.emit(
                    try NWCFixtures.response(
                        resultJSON: #"{"result_type":"get_balance","result":{"balance":5000}}"#,
                        requestID: request.id, client: client, wallet: wallet))
            } else if json.contains("pay_invoice") {
                await transport.emit(
                    try NWCFixtures.response(
                        resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"aa"}}"#,
                        requestID: request.id, client: client, wallet: wallet))
            }
        }

        #expect(try await balance.balance == 5000)
        #expect(try await payment.preimage == "aa")
    }

    @Test("concurrent commands start the transport only once")
    func startsOnce() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        async let balance = connection.getBalance()
        async let payment = connection.payInvoice("lnbc1")

        let requests = try await NWCFixtures.waitForSentEvents(transport, count: 2)
        #expect(await transport.connectCount == 1)

        for request in requests {
            let json = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
            if json.contains("get_balance") {
                await transport.emit(
                    try NWCFixtures.response(
                        resultJSON: #"{"result_type":"get_balance","result":{"balance":1}}"#,
                        requestID: request.id, client: client, wallet: wallet))
            } else {
                await transport.emit(
                    try NWCFixtures.response(
                        resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"a"}}"#,
                        requestID: request.id, client: client, wallet: wallet))
            }
        }
        _ = try await balance
        _ = try await payment
    }

    @Test("a wallet error response is thrown as a typed error")
    func walletErrorResponse() async throws {
        let (connection, transport, client, wallet) = try makeConnection()

        async let result = connection.payInvoice("lnbc1")
        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON:
                    #"{"result_type":"pay_invoice","error":{"code":"INSUFFICIENT_BALANCE","message":"no funds"}}"#,
                requestID: request.id, client: client, wallet: wallet))

        do {
            _ = try await result
            Issue.record("expected a wallet error")
        } catch let WalletConnectError.walletError(code, message) {
            #expect(code == .insufficientBalance)
            #expect(message == "no funds")
        }
    }

    @Test("a request times out when no response arrives")
    func requestTimeout() async throws {
        let (connection, _, _, _) = try makeConnection(timeout: 0.2)
        await #expect(throws: WalletConnectError.timedOut) {
            _ = try await connection.payInvoice("lnbc1")
        }
    }

    @Test("multi_pay_invoice correlates by d tag and surfaces partial completion")
    func multiPayPartial() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 0.4)

        async let results = connection.multiPayInvoice([
            .init(id: "a", invoice: "lnbc1"),
            .init(id: "b", invoice: "lnbc2"),
        ])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        // Respond for invoice "a" only; "b" never answers, so the call returns partial after timeout.
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"pa"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "a"))

        let mapped = try await results
        #expect(mapped.count == 1)
        #expect(try mapped["a"]?.get().preimage == "pa")
        #expect(mapped["b"] == nil)
    }

    @Test("multi_pay_invoice completes promptly when a response cannot be decrypted")
    func multiPayUndecryptableCompletesPromptly() async throws {
        let (connection, transport, client, wallet) = try makeConnection(timeout: 5)

        async let results = connection.multiPayInvoice([
            .init(id: "a", invoice: "lnbc1"),
            .init(id: "b", invoice: "lnbc2"),
        ])

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"multi_pay_invoice","result":{"preimage":"pa"}}"#,
                requestID: request.id, client: client, wallet: wallet, dTag: "a"))
        // A second response that cannot be decrypted must still count toward completion.
        await transport.emit(
            Event(
                id: "resp-garbage", pubkey: wallet.publicKeyHex, createdAt: 0,
                kind: .walletConnectResponse,
                tags: [["e", request.id], ["p", client.publicKeyHex], ["d", "b"]],
                content: "not-decryptable", sig: ""))

        let clock = ContinuousClock()
        let start = clock.now
        let mapped = try await results
        let elapsed = clock.now - start

        #expect(mapped.count == 1)
        #expect(try mapped["a"]?.get().preimage == "pa")
        // Far below the 5s timeout: completion fired once both responses arrived.
        #expect(elapsed < .seconds(1))
    }
}
