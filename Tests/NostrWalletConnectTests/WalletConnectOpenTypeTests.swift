import Foundation
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnectMethod and WalletConnectErrorCode Tests")
struct WalletConnectOpenTypeTests {
    @Test("method constants carry their NIP-47 wire names")
    func methodWireValues() {
        let expected: [(WalletConnectMethod, String)] = [
            (.payInvoice, "pay_invoice"),
            (.multiPayInvoice, "multi_pay_invoice"),
            (.payKeysend, "pay_keysend"),
            (.multiPayKeysend, "multi_pay_keysend"),
            (.makeInvoice, "make_invoice"),
            (.lookupInvoice, "lookup_invoice"),
            (.listTransactions, "list_transactions"),
            (.getBalance, "get_balance"),
            (.getInfo, "get_info"),
        ]
        for (method, raw) in expected {
            #expect(method.rawValue == raw)
            #expect(method.description == raw)
            #expect(WalletConnectMethod(rawValue: raw) == method)
        }
    }

    @Test("an unknown method round-trips through init(rawValue:) and Codable as a bare string")
    func unknownMethodRoundTrip() throws {
        let method = WalletConnectMethod(rawValue: "sign_message")
        #expect(method.rawValue == "sign_message")

        let data = try JSONEncoder().encode(method)
        #expect(String(decoding: data, as: UTF8.self) == #""sign_message""#)
        #expect(try JSONDecoder().decode(WalletConnectMethod.self, from: data) == method)
    }

    @Test("a method decodes from a JSON string and rejects a non-string")
    func methodDecoding() throws {
        let decoded = try JSONDecoder().decode([WalletConnectMethod].self, from: Data(#"["pay_invoice","x"]"#.utf8))
        #expect(decoded == [.payInvoice, WalletConnectMethod(rawValue: "x")])
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(WalletConnectMethod.self, from: Data("1".utf8))
        }
    }

    @Test("error code constants carry their NIP-47 wire codes")
    func errorCodeWireValues() {
        let expected: [(WalletConnectErrorCode, String)] = [
            (.rateLimited, "RATE_LIMITED"),
            (.notImplemented, "NOT_IMPLEMENTED"),
            (.insufficientBalance, "INSUFFICIENT_BALANCE"),
            (.quotaExceeded, "QUOTA_EXCEEDED"),
            (.restricted, "RESTRICTED"),
            (.unauthorized, "UNAUTHORIZED"),
            (.internal, "INTERNAL"),
            (.unsupportedEncryption, "UNSUPPORTED_ENCRYPTION"),
            (.paymentFailed, "PAYMENT_FAILED"),
            (.other, "OTHER"),
        ]
        for (code, raw) in expected {
            #expect(code.rawValue == raw)
            #expect(code.description == raw)
            #expect(WalletConnectErrorCode(rawValue: raw) == code)
        }
    }

    @Test("an unknown error code round-trips through init(rawValue:) and Codable as a bare string")
    func unknownErrorCodeRoundTrip() throws {
        let code = WalletConnectErrorCode(rawValue: "SOMETHING_NEW")
        #expect(code.rawValue == "SOMETHING_NEW")
        #expect(code != .other)

        let data = try JSONEncoder().encode(code)
        #expect(String(decoding: data, as: UTF8.self) == #""SOMETHING_NEW""#)
        #expect(try JSONDecoder().decode(WalletConnectErrorCode.self, from: data) == code)
    }

    @Test("unexpectedResultType describes the typed methods by their wire names")
    func unexpectedResultTypeDescription() {
        let error = WalletConnectError.unexpectedResultType(
            expected: .payInvoice, received: WalletConnectMethod(rawValue: "future_method"))
        #expect(error.errorDescription == "The wallet answered a pay_invoice request with a future_method response")
    }
}
