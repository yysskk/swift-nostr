import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

/// Drives each typed command against a fake wallet and checks the decrypted request it sends: the
/// method, and params built from the command's labeled arguments.
@Suite("WalletConnection Command Tests")
struct WalletConnectionCommandTests {
    /// The decrypted request body a command sent, and what the command returned.
    private struct Exchange<Output> {
        let method: JSONValue?
        let params: JSONValue?
        let output: Output
    }

    /// Runs `command` on a fresh connection, answers its request with `resultJSON`, and returns the
    /// request the wallet received alongside the command's return value.
    private func exchange<Output: Sendable>(
        answering resultJSON: String,
        _ command: @escaping @Sendable (WalletConnection) async throws -> Output
    ) async throws -> Exchange<Output> {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let uri = try NWCFixtures.uri(wallet: wallet, client: client)
        let config = WalletConnection.Config(requestTimeout: .seconds(5), preferredEncryption: .nip44)
        let connection = WalletConnection(uri: uri, transport: transport, config: config)

        let task = Task { try await command(connection) }
        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        let json = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
        let body = try JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))

        let response = try NWCFixtures.response(
            resultJSON: resultJSON, requestID: request.id, client: client, wallet: wallet)
        await transport.emit(response)
        let output = try await task.value
        return Exchange(method: body["method"], params: body["params"], output: output)
    }

    private static let paymentResultJSON =
        #"{"result_type":"pay_invoice","result":{"preimage":"0011","fees_paid":7}}"#

    // MARK: - pay_invoice

    @Test("payInvoice sends every argument as params")
    func payInvoiceAllArguments() async throws {
        let exchange = try await exchange(answering: Self.paymentResultJSON) { connection in
            try await connection.payInvoice("lnbc1", amount: 21000, metadata: ["order": .string("X1")])
        }
        #expect(exchange.method == .string("pay_invoice"))
        let expected: JSONValue = .object([
            "invoice": .string("lnbc1"),
            "amount": .int(21000),
            "metadata": .object(["order": .string("X1")]),
        ])
        #expect(exchange.params == expected)
        #expect(exchange.output == PaymentResult(preimage: "0011", feesPaid: 7))
    }

    @Test("payInvoice omits the defaulted arguments")
    func payInvoiceDefaults() async throws {
        let exchange = try await exchange(answering: Self.paymentResultJSON) { connection in
            try await connection.payInvoice("lnbc1")
        }
        #expect(exchange.params == .object(["invoice": .string("lnbc1")]))
    }

    // MARK: - pay_keysend

    @Test("payKeysend sends every argument as params")
    func payKeysendAllArguments() async throws {
        let resultJSON = #"{"result_type":"pay_keysend","result":{"preimage":"ff"}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.payKeysend(
                amount: 1000, nodePublicKey: "02abc", preimage: "ee",
                tlvRecords: [TLVRecord(type: 696_969, value: "beef")])
        }
        #expect(exchange.method == .string("pay_keysend"))
        let record: JSONValue = .object(["type": .int(696_969), "value": .string("beef")])
        let expected: JSONValue = .object([
            "amount": .int(1000),
            "pubkey": .string("02abc"),
            "preimage": .string("ee"),
            "tlv_records": .array([record]),
        ])
        #expect(exchange.params == expected)
        #expect(exchange.output == PaymentResult(preimage: "ff"))
    }

    @Test("payKeysend omits the defaulted arguments")
    func payKeysendDefaults() async throws {
        let resultJSON = #"{"result_type":"pay_keysend","result":{"preimage":"ff"}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.payKeysend(amount: 1000, nodePublicKey: "02abc")
        }
        #expect(exchange.params == .object(["amount": .int(1000), "pubkey": .string("02abc")]))
    }

    // MARK: - make_invoice

    @Test("makeInvoice sends every argument as params")
    func makeInvoiceAllArguments() async throws {
        let resultJSON = #"{"result_type":"make_invoice","result":{"type":"incoming","amount":5000}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.makeInvoice(
                amount: 5000, description: "coffee", descriptionHash: "dd", expiry: .seconds(3600),
                metadata: ["table": .int(4)])
        }
        #expect(exchange.method == .string("make_invoice"))
        let expected: JSONValue = .object([
            "amount": .int(5000),
            "description": .string("coffee"),
            "description_hash": .string("dd"),
            "expiry": .int(3600),
            "metadata": .object(["table": .int(4)]),
        ])
        #expect(exchange.params == expected)
        #expect(exchange.output.type == .incoming)
        #expect(exchange.output.amount == 5000)
    }

    @Test("makeInvoice omits the defaulted arguments")
    func makeInvoiceDefaults() async throws {
        let resultJSON = #"{"result_type":"make_invoice","result":{"type":"incoming","amount":5000}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.makeInvoice(amount: 5000)
        }
        #expect(exchange.params == .object(["amount": .int(5000)]))
    }

    // MARK: - lookup_invoice

    @Test(
        "lookupInvoice sends only the key it is given",
        arguments: [
            (LookupInvoiceRequest.Key.paymentHash("aa"), "payment_hash", "aa"),
            (LookupInvoiceRequest.Key.invoice("lnbc1"), "invoice", "lnbc1"),
        ])
    func lookupInvoice(key: LookupInvoiceRequest.Key, wireKey: String, value: String) async throws {
        let resultJSON = #"{"result_type":"lookup_invoice","result":{"type":"incoming","amount":1}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.lookupInvoice(key)
        }
        #expect(exchange.method == .string("lookup_invoice"))
        #expect(exchange.params == .object([wireKey: .string(value)]))
        #expect(exchange.output.amount == 1)
    }

    // MARK: - list_transactions

    @Test("listTransactions sends every argument as params")
    func listTransactionsAllArguments() async throws {
        let resultJSON = """
            {"result_type":"list_transactions","result":{"transactions":[
            {"type":"incoming","amount":1000},{"type":"incoming","amount":2000}]}}
            """
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.listTransactions(
                from: Timestamp(rawValue: 1_700_000_000), until: Timestamp(rawValue: 1_700_086_400),
                limit: 10, offset: 20, unpaid: true, type: .incoming)
        }
        #expect(exchange.method == .string("list_transactions"))
        let expected: JSONValue = .object([
            "from": .int(1_700_000_000),
            "until": .int(1_700_086_400),
            "limit": .int(10),
            "offset": .int(20),
            "unpaid": .bool(true),
            "type": .string("incoming"),
        ])
        #expect(exchange.params == expected)
        #expect(exchange.output.map(\.amount) == [1000, 2000])
    }

    @Test("listTransactions with no arguments sends empty params")
    func listTransactionsDefaults() async throws {
        let resultJSON = #"{"result_type":"list_transactions","result":{"transactions":[]}}"#
        let exchange = try await exchange(answering: resultJSON) { connection in
            try await connection.listTransactions()
        }
        #expect(exchange.params == .object([:]))
        #expect(exchange.output.isEmpty)
    }
}
