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
        #expect(result.nodePublicKey == "02abc")
        #expect(result.blockHeight == 830_000)
        #expect(result.methods == [.payInvoice, .getBalance])
        #expect(result.notifications == [.paymentReceived])
    }

    @Test("get_info encodes nodePublicKey under the wire key public key")
    func encodeGetInfoNodePublicKey() throws {
        let data = try JSONEncoder().encode(GetInfoResult(nodePublicKey: "02abc"))
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("expected a JSON object")
            return
        }
        #expect(object["pubkey"] == .string("02abc"))
        #expect(object["nodePublicKey"] == nil)
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
        #expect(tx.type == .incoming)
        #expect(tx.state == .settled)
        #expect(tx.paymentHash == "aaaa")
        #expect(tx.amount == 21000)
        #expect(tx.feesPaid == 0)
        #expect(tx.createdAt == Timestamp(rawValue: 1_700_000_000))
        #expect(tx.expiresAt == Timestamp(rawValue: 1_700_003_600))
        #expect(tx.settledAt == Timestamp(rawValue: 1_700_000_100))
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

    @Test("a transaction encodes its times as integer Unix seconds under the NIP-47 keys")
    func encodeTransactionTimes() throws {
        let transaction = WalletConnectTransaction(
            type: .incoming, amount: 21000, createdAt: Timestamp(rawValue: 1_700_000_000),
            expiresAt: Timestamp(rawValue: 1_700_003_600), settledAt: Timestamp(rawValue: 1_700_000_100))
        let data = try JSONEncoder().encode(transaction)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("a transaction should encode as a JSON object")
            return
        }
        #expect(object["created_at"] == .int(1_700_000_000))
        #expect(object["expires_at"] == .int(1_700_003_600))
        #expect(object["settled_at"] == .int(1_700_000_100))
        #expect(try JSONDecoder().decode(WalletConnectTransaction.self, from: data) == transaction)
    }

    @Test("a transaction without times leaves them nil")
    func decodeTransactionWithoutTimes() throws {
        let json = #"{"result_type":"lookup_invoice","result":{"type":"outgoing","amount":1}}"#
        let tx = try #require(try decode(json, as: WalletConnectTransaction.self).result)
        #expect(tx.createdAt == nil)
        #expect(tx.expiresAt == nil)
        #expect(tx.settledAt == nil)
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
        #expect(result.transactions[0].type == .incoming)
        #expect(result.transactions[1].type == .outgoing)
        #expect(result.transactions[1].feesPaid == 1)
    }

    @Test("get_info keeps methods and notification types it has no constant for, and encodes them as strings")
    func getInfoUnknownMethodsAndNotifications() throws {
        let json = """
            {"result_type":"get_info","result":{"methods":["pay_invoice","sign_message"],
            "notifications":["payment_sent","hold_invoice_accepted"]}}
            """
        let result = try #require(try decode(json, as: GetInfoResult.self).result)
        #expect(result.methods == [.payInvoice, WalletConnectMethod(rawValue: "sign_message")])
        #expect(
            result.notifications == [.paymentSent, WalletConnectNotificationType(rawValue: "hold_invoice_accepted")])

        let data = try JSONEncoder().encode(result)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("expected a JSON object")
            return
        }
        #expect(object["methods"] == .array([.string("pay_invoice"), .string("sign_message")]))
        #expect(object["notifications"] == .array([.string("payment_sent"), .string("hold_invoice_accepted")]))
    }

    @Test("a transaction encodes its type and state as the NIP-47 strings")
    func encodeTransactionTypeAndState() throws {
        let transaction = WalletConnectTransaction(type: .outgoing, state: .failed, amount: 1)
        let data = try JSONEncoder().encode(transaction)
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("a transaction should encode as a JSON object")
            return
        }
        #expect(object["type"] == .string("outgoing"))
        #expect(object["state"] == .string("failed"))
        #expect(try JSONDecoder().decode(WalletConnectTransaction.self, from: data) == transaction)
    }

    @Test("a transaction keeps a state it has no constant for")
    func decodeUnknownTransactionState() throws {
        let json = #"{"result_type":"lookup_invoice","result":{"type":"incoming","state":"accepted","amount":1}}"#
        let tx = try #require(try decode(json, as: WalletConnectTransaction.self).result)
        #expect(tx.state == TransactionState(rawValue: "accepted"))
    }

    @Test("a transaction keeps a type it has no constant for, and a list with one still decodes")
    func decodeUnknownTransactionType() throws {
        let json =
            #"{"result_type":"list_transactions","result":{"transactions":"#
            + #"[{"type":"internal","amount":1},{"type":"incoming","amount":2}]}}"#
        let result = try #require(try decode(json, as: ListTransactionsResult.self).result)
        #expect(result.transactions.map(\.type) == [TransactionType(rawValue: "internal"), .incoming])
    }

    @Test("a list_transactions request encodes its type filter as the NIP-47 string")
    func encodeListTransactionsTypeFilter() throws {
        let data = try JSONEncoder().encode(ListTransactionsRequest(type: .outgoing))
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("expected a JSON object")
            return
        }
        #expect(object["type"] == .string("outgoing"))
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
        #expect(error.code == .insufficientBalance)
    }

    @Test("decodes an unrecognized error code verbatim")
    func decodeUnknownErrorCode() throws {
        let json = #"{"result_type":"pay_invoice","error":{"code":"SOMETHING_NEW","message":"?"}}"#
        let error = try #require(try decode(json, as: PayInvoiceResult.self).error)
        #expect(error.code == WalletConnectErrorCode(rawValue: "SOMETHING_NEW"))
    }
}
