import Foundation
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnect Request Encoding Tests")
struct WalletConnectRequestTests {
    /// Encodes `value` and decodes it back into a `JSONValue` so assertions read the wire shape
    /// without platform-specific `NSNumber` bridging.
    private func wire<T: Encodable>(_ value: T) throws -> [String: JSONValue] {
        let data = try JSONEncoder().encode(value)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw WireError.notAnObject
        }
        return object
    }

    private func params(_ root: [String: JSONValue]) throws -> [String: JSONValue] {
        guard case .object(let params)? = root["params"] else { throw WireError.notAnObject }
        return params
    }

    private enum WireError: Error { case notAnObject }

    /// The envelope `send(_:)` builds: the request's own `method` with the request as `params`.
    private func envelope<Request: WalletConnectRequest>(_ request: Request) throws -> [String: JSONValue] {
        try wire(RequestEnvelope(method: Request.method, params: request))
    }

    @Test("built-in requests are sent under their NIP-47 methods")
    func builtInRequestMethods() throws {
        #expect(try envelope(PayInvoiceRequest(invoice: "lnbc1"))["method"] == .string("pay_invoice"))
        #expect(
            try envelope(PayKeysendRequest(amount: 1, nodePublicKey: "02abc"))["method"] == .string("pay_keysend"))
        #expect(try envelope(MakeInvoiceRequest(amount: 1))["method"] == .string("make_invoice"))
        #expect(try envelope(LookupInvoiceRequest(.invoice("lnbc1")))["method"] == .string("lookup_invoice"))
        #expect(try envelope(ListTransactionsRequest())["method"] == .string("list_transactions"))
        #expect(try envelope(GetBalanceRequest())["method"] == .string("get_balance"))
        #expect(try envelope(GetInfoRequest())["method"] == .string("get_info"))
    }

    @Test("get_balance and get_info send empty params")
    func emptyRequests() throws {
        #expect(try wire(GetBalanceRequest()).isEmpty)
        #expect(try wire(GetInfoRequest()).isEmpty)
        #expect(try envelope(GetBalanceRequest())["params"] == .object([:]))
        #expect(try envelope(GetInfoRequest())["params"] == .object([:]))
    }

    @Test("pay_invoice encodes method and params")
    func payInvoice() throws {
        let root = try envelope(PayInvoiceRequest(invoice: "lnbc1", amount: 123))
        #expect(root["method"] == .string("pay_invoice"))
        let params = try params(root)
        #expect(params["invoice"] == .string("lnbc1"))
        #expect(params["amount"] == .int(123))
    }

    @Test("nil optional params are omitted from the wire form")
    func omitsNilParams() throws {
        let root = try wire(RequestEnvelope(method: .payInvoice, params: PayInvoiceRequest(invoice: "lnbc1")))
        let params = try params(root)
        #expect(params["amount"] == nil)
        #expect(params["metadata"] == nil)
    }

    @Test("make_invoice uses snake_case keys")
    func makeInvoiceSnakeCase() throws {
        let root = try wire(
            RequestEnvelope(
                method: .makeInvoice, params: MakeInvoiceRequest(amount: 1000, descriptionHash: "abcd")))
        let params = try params(root)
        #expect(params["description_hash"] == .string("abcd"))
        #expect(params["descriptionHash"] == nil)
    }

    @Test("make_invoice encodes expiry as whole seconds, truncating a fraction")
    func makeInvoiceExpiryEncodesSeconds() throws {
        let hour = try wire(MakeInvoiceRequest(amount: 1000, expiry: .seconds(3600)))
        #expect(hour["expiry"] == .int(3600))

        let fractional = try wire(MakeInvoiceRequest(amount: 1000, expiry: .milliseconds(90_900)))
        #expect(fractional["expiry"] == .int(90))

        let absent = try wire(MakeInvoiceRequest(amount: 1000))
        #expect(absent["expiry"] == nil)
    }

    @Test("make_invoice decodes expiry from integer seconds")
    func makeInvoiceExpiryDecodesSeconds() throws {
        let json = Data(#"{"amount":1000,"description":"coffee","expiry":600}"#.utf8)
        let params = try JSONDecoder().decode(MakeInvoiceRequest.self, from: json)

        #expect(params == MakeInvoiceRequest(amount: 1000, description: "coffee", expiry: .seconds(600)))
        #expect(try JSONDecoder().decode(MakeInvoiceRequest.self, from: Data(#"{"amount":1}"#.utf8)).expiry == nil)
    }

    @Test("pay_keysend encodes tlv_records with a numeric type")
    func payKeysendTLV() throws {
        let root = try wire(
            RequestEnvelope(
                method: .payKeysend,
                params: PayKeysendRequest(
                    amount: 1000, nodePublicKey: "02abc", tlvRecords: [TLVRecord(type: 696_969, value: "deadbeef")])))
        let params = try params(root)
        guard case .array(let records)? = params["tlv_records"], case .object(let first)? = records.first else {
            Issue.record("expected a tlv_records array")
            return
        }
        #expect(first["type"] == .int(696_969))
        #expect(first["value"] == .string("deadbeef"))
    }

    @Test("pay_keysend encodes nodePublicKey under the wire key public key")
    func payKeysendNodePublicKeyWireKey() throws {
        let params = try params(
            wire(
                RequestEnvelope(
                    method: .payKeysend, params: PayKeysendRequest(amount: 1000, nodePublicKey: "02abc"))))
        #expect(params["pubkey"] == .string("02abc"))
        #expect(params["nodePublicKey"] == nil)
    }

    @Test("multi_pay_keysend encodes each keysend's nodePublicKey under the wire key public key")
    func multiPayKeysendNodePublicKeyWireKey() throws {
        let params = try params(
            wire(
                RequestEnvelope(
                    method: .multiPayKeysend,
                    params: MultiPayKeysendParams(keysends: [.init(nodePublicKey: "02abc", amount: 1000)]))))
        guard case .array(let keysends)? = params["keysends"], case .object(let first)? = keysends.first else {
            Issue.record("expected a keysends array")
            return
        }
        #expect(first["pubkey"] == .string("02abc"))
        #expect(first["nodePublicKey"] == nil)
    }

    @Test("multi_pay_invoice encodes each invoice and omits a nil id")
    func multiPayInvoice() throws {
        let root = try wire(
            RequestEnvelope(
                method: .multiPayInvoice,
                params: MultiPayInvoiceParams(invoices: [
                    .init(id: "a", invoice: "lnbc1", amount: 100),
                    .init(invoice: "lnbc2"),
                ])))
        let params = try params(root)
        guard case .array(let invoices)? = params["invoices"], invoices.count == 2,
            case .object(let first) = invoices[0], case .object(let second) = invoices[1]
        else {
            Issue.record("expected two invoices")
            return
        }
        #expect(first["id"] == .string("a"))
        #expect(first["amount"] == .int(100))
        #expect(second["id"] == nil)
    }

    @Test("lookup_invoice by payment hash sends only payment_hash")
    func lookupByPaymentHash() throws {
        let params = try wire(LookupInvoiceRequest(.paymentHash("aa")))
        #expect(params == ["payment_hash": .string("aa")])
    }

    @Test("lookup_invoice by invoice sends only invoice")
    func lookupByInvoice() throws {
        let params = try wire(LookupInvoiceRequest(.invoice("lnbc1")))
        #expect(params == ["invoice": .string("lnbc1")])
    }

    @Test(
        "lookup_invoice decodes exactly one key",
        arguments: [
            (#"{"payment_hash":"aa"}"#, LookupInvoiceRequest.Key.paymentHash("aa")),
            (#"{"invoice":"lnbc1"}"#, LookupInvoiceRequest.Key.invoice("lnbc1")),
        ])
    func lookupDecodesOneKey(json: String, key: LookupInvoiceRequest.Key) throws {
        let request = try JSONDecoder().decode(LookupInvoiceRequest.self, from: Data(json.utf8))
        #expect(request.key == key)
    }

    @Test(
        "lookup_invoice decoding rejects both keys or neither",
        arguments: [#"{"payment_hash":"aa","invoice":"lnbc1"}"#, "{}"])
    func lookupRejectsBothOrNeither(json: String) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LookupInvoiceRequest.self, from: Data(json.utf8))
        }
    }

    @Test("list_transactions encodes the transaction type")
    func listTransactionsType() throws {
        let root = try wire(
            RequestEnvelope(method: .listTransactions, params: ListTransactionsRequest(type: .incoming)))
        let params = try params(root)
        #expect(params["type"] == .string("incoming"))
    }

    @Test("list_transactions encodes from and until as integer Unix seconds")
    func listTransactionsTimeRange() throws {
        let root = try wire(
            RequestEnvelope(
                method: .listTransactions,
                params: ListTransactionsRequest(
                    from: Timestamp(rawValue: 1_700_000_000), until: Timestamp(rawValue: 1_700_086_400))))
        let params = try params(root)
        #expect(params["from"] == .int(1_700_000_000))
        #expect(params["until"] == .int(1_700_086_400))
    }

    @Test("list_transactions omits an unset time range")
    func listTransactionsOmitsTimeRange() throws {
        let params = try params(
            wire(RequestEnvelope(method: .listTransactions, params: ListTransactionsRequest())))
        #expect(params["from"] == nil)
        #expect(params["until"] == nil)
    }

    @Test("metadata keys are preserved verbatim (no snake_case mangling)")
    func metadataKeysPreserved() throws {
        let metadata: [String: JSONValue] = [
            "order_id": .string("X1"),
            "nested": .object(["fooBar": .int(5)]),
        ]
        let root = try wire(
            RequestEnvelope(method: .payInvoice, params: PayInvoiceRequest(invoice: "lnbc1", metadata: metadata)))
        let params = try params(root)
        guard case .object(let decoded)? = params["metadata"] else {
            Issue.record("expected metadata object")
            return
        }
        #expect(decoded["order_id"] == .string("X1"))
        #expect(decoded["nested"] == .object(["fooBar": .int(5)]))
    }
}
