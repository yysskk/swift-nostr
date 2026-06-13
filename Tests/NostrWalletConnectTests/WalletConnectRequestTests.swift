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

    @Test("pay_invoice encodes method and params")
    func payInvoice() throws {
        let root = try wire(
            WalletConnectRequest(method: .payInvoice, params: PayInvoiceParams(invoice: "lnbc1", amount: 123)))
        #expect(root["method"] == .string("pay_invoice"))
        let params = try params(root)
        #expect(params["invoice"] == .string("lnbc1"))
        #expect(params["amount"] == .int(123))
    }

    @Test("nil optional params are omitted from the wire form")
    func omitsNilParams() throws {
        let root = try wire(WalletConnectRequest(method: .payInvoice, params: PayInvoiceParams(invoice: "lnbc1")))
        let params = try params(root)
        #expect(params["amount"] == nil)
        #expect(params["metadata"] == nil)
    }

    @Test("make_invoice uses snake_case keys")
    func makeInvoiceSnakeCase() throws {
        let root = try wire(
            WalletConnectRequest(
                method: .makeInvoice, params: MakeInvoiceParams(amount: 1000, descriptionHash: "abcd")))
        let params = try params(root)
        #expect(params["description_hash"] == .string("abcd"))
        #expect(params["descriptionHash"] == nil)
    }

    @Test("pay_keysend encodes tlv_records with a numeric type")
    func payKeysendTLV() throws {
        let root = try wire(
            WalletConnectRequest(
                method: .payKeysend,
                params: PayKeysendParams(
                    amount: 1000, pubkey: "02abc", tlvRecords: [TLVRecord(type: 696_969, value: "deadbeef")])))
        let params = try params(root)
        guard case .array(let records)? = params["tlv_records"], case .object(let first)? = records.first else {
            Issue.record("expected a tlv_records array")
            return
        }
        #expect(first["type"] == .int(696_969))
        #expect(first["value"] == .string("deadbeef"))
    }

    @Test("multi_pay_invoice encodes each invoice and omits a nil id")
    func multiPayInvoice() throws {
        let root = try wire(
            WalletConnectRequest(
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
        let root = try wire(
            WalletConnectRequest(method: .lookupInvoice, params: LookupInvoiceParams.paymentHash("aa")))
        let params = try params(root)
        #expect(params["payment_hash"] == .string("aa"))
        #expect(params["invoice"] == nil)
    }

    @Test("list_transactions encodes the transaction type")
    func listTransactionsType() throws {
        let root = try wire(
            WalletConnectRequest(method: .listTransactions, params: ListTransactionsParams(type: .incoming)))
        let params = try params(root)
        #expect(params["type"] == .string("incoming"))
    }

    @Test("metadata keys are preserved verbatim (no snake_case mangling)")
    func metadataKeysPreserved() throws {
        let metadata: [String: JSONValue] = [
            "order_id": .string("X1"),
            "nested": .object(["fooBar": .int(5)]),
        ]
        let root = try wire(
            WalletConnectRequest(method: .payInvoice, params: PayInvoiceParams(invoice: "lnbc1", metadata: metadata)))
        let params = try params(root)
        guard case .object(let decoded)? = params["metadata"] else {
            Issue.record("expected metadata object")
            return
        }
        #expect(decoded["order_id"] == .string("X1"))
        #expect(decoded["nested"] == .object(["fooBar": .int(5)]))
    }
}
