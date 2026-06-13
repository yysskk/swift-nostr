import Foundation
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnect Response Decoding Tests")
struct WalletConnectResponseTests {
    private func decode<Result: Decodable>(_ json: String, as _: Result.Type) throws -> WalletConnectResponse<Result> {
        try JSONDecoder().decode(WalletConnectResponse<Result>.self, from: Data(json.utf8))
    }

    @Test("decodes a get_info result with snake_case fields")
    func decodeGetInfo() throws {
        let json = """
            {"result_type":"get_info","error":null,"result":{"alias":"Alby","color":"#ff9900",
            "pubkey":"02abc","network":"mainnet","block_height":830000,"block_hash":"0000abc",
            "methods":["pay_invoice","get_balance"],"notifications":["payment_received"]}}
            """
        let response = try decode(json, as: GetInfoResult.self)
        #expect(response.resultType == "get_info")
        #expect(response.error == nil)
        let result = try #require(response.result)
        #expect(result.alias == "Alby")
        #expect(result.blockHeight == 830_000)
        #expect(result.methods == ["pay_invoice", "get_balance"])
        #expect(result.notifications == ["payment_received"])
    }

    @Test("decodes a transaction with all snake_case fields")
    func decodeTransaction() throws {
        let json = """
            {"result_type":"lookup_invoice","result":{"type":"incoming","state":"settled",
            "invoice":"lnbc1","description":"coffee","description_hash":"abcd","preimage":"ffff",
            "payment_hash":"aaaa","amount":21000,"fees_paid":0,"created_at":1700000000,
            "expires_at":1700003600,"settled_at":1700000100,"metadata":{"k":"v"}}}
            """
        let response = try decode(json, as: WalletConnectTransaction.self)
        let tx = try #require(response.result)
        #expect(tx.type == "incoming")
        #expect(tx.paymentHash == "aaaa")
        #expect(tx.amount == 21000)
        #expect(tx.feesPaid == 0)
        #expect(tx.createdAt == 1_700_000_000)
        #expect(tx.settledAt == 1_700_000_100)
        #expect(tx.metadata?["k"] == .string("v"))
    }

    @Test("get_info defaults methods to empty when the field is omitted")
    func decodeGetInfoMissingMethods() throws {
        let json = #"{"result_type":"get_info","result":{"alias":"X"}}"#
        let response = try decode(json, as: GetInfoResult.self)
        let result = try #require(response.result)
        #expect(result.methods == [])
        #expect(result.notifications == nil)
    }

    @Test("decodes a pay_invoice result")
    func decodePayInvoice() throws {
        let json = #"{"result_type":"pay_invoice","result":{"preimage":"0011","fees_paid":100}}"#
        let response = try decode(json, as: PayInvoiceResult.self)
        let result = try #require(response.result)
        #expect(result.preimage == "0011")
        #expect(result.feesPaid == 100)
    }

    @Test("decodes a list_transactions result")
    func decodeListTransactions() throws {
        let json = """
            {"result_type":"list_transactions","result":{"transactions":[
            {"type":"incoming","amount":1000,"payment_hash":"aa"},
            {"type":"outgoing","amount":2000,"payment_hash":"bb","fees_paid":1}]}}
            """
        let response = try decode(json, as: ListTransactionsResult.self)
        let result = try #require(response.result)
        #expect(result.transactions.count == 2)
        #expect(result.transactions[0].type == "incoming")
        #expect(result.transactions[1].feesPaid == 1)
    }

    @Test("decodes an error response")
    func decodeError() throws {
        let json = """
            {"result_type":"pay_invoice","error":{"code":"INSUFFICIENT_BALANCE","message":"no funds"},
            "result":null}
            """
        let response = try decode(json, as: PayInvoiceResult.self)
        #expect(response.result == nil)
        let error = try #require(response.error)
        #expect(error.code == "INSUFFICIENT_BALANCE")
        #expect(WalletConnectErrorCode(rawValue: error.code) == .insufficientBalance)
    }

    @Test("maps every known error code and preserves unknown ones")
    func errorCodeMapping() {
        let known: [(String, WalletConnectErrorCode)] = [
            ("RATE_LIMITED", .rateLimited),
            ("NOT_IMPLEMENTED", .notImplemented),
            ("INSUFFICIENT_BALANCE", .insufficientBalance),
            ("QUOTA_EXCEEDED", .quotaExceeded),
            ("RESTRICTED", .restricted),
            ("UNAUTHORIZED", .unauthorized),
            ("INTERNAL", .internal),
            ("UNSUPPORTED_ENCRYPTION", .unsupportedEncryption),
            ("PAYMENT_FAILED", .paymentFailed),
            ("OTHER", .other),
        ]
        for (raw, code) in known {
            #expect(WalletConnectErrorCode(rawValue: raw) == code)
            #expect(code.rawValue == raw)
        }
        #expect(WalletConnectErrorCode(rawValue: "SOMETHING_NEW") == .unknown("SOMETHING_NEW"))
        #expect(WalletConnectErrorCode.unknown("SOMETHING_NEW").rawValue == "SOMETHING_NEW")
    }
}
