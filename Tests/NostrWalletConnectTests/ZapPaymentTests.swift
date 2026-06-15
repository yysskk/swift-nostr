import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("Zap Payment Capstone Tests", .serialized)
struct ZapPaymentTests {
    private func payResponse() -> LNURLPayResponse {
        LNURLPayResponse(
            callback: "https://example.com/lnurl/callback",
            minSendable: 1000,
            maxSendable: 1_000_000_000,
            allowsNostr: true,
            nostrPubkey: String(repeating: "0", count: 64))
    }

    @Test("payZap fetches the invoice and pays it, returning the preimage")
    func payZapCompletes() async throws {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let zapSigner = EventSigner(keyPair: try KeyPair())
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client),
            transport: transport,
            config: .init(requestTimeout: 2, preferredEncryption: .nip44))

        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseBody = Data(#"{"pr":"lnbc210n1pzapinvoice"}"#.utf8)
        let zapRequest = try zapSigner.signZapRequest(
            recipientPubkey: String(repeating: "1", count: 64), relays: ["wss://relay.example"],
            amountMillisats: 21000)

        async let result = connection.payZap(
            lnurlPay: payResponse(),
            amountMillisats: 21000,
            zapRequest: zapRequest,
            urlSession: MockURLProtocol.makeSession())

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        let json = try NWCFixtures.decryptRequest(request, client: client, wallet: wallet)
        #expect(json.contains("pay_invoice"))
        #expect(json.contains("lnbc210n1pzapinvoice"))

        await transport.emit(
            try NWCFixtures.response(
                resultJSON: #"{"result_type":"pay_invoice","result":{"preimage":"abc123","fees_paid":3}}"#,
                requestID: request.id, client: client, wallet: wallet))

        let zap = try await result
        #expect(zap.invoice == "lnbc210n1pzapinvoice")
        #expect(zap.preimage == "abc123")
        #expect(zap.feesPaid == 3)
    }

    @Test("payZap propagates a wallet payment error after fetching the invoice")
    func payZapPropagatesWalletError() async throws {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let zapSigner = EventSigner(keyPair: try KeyPair())
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client),
            transport: transport,
            config: .init(requestTimeout: 2, preferredEncryption: .nip44))

        MockURLProtocol.statusCode = 200
        MockURLProtocol.responseBody = Data(#"{"pr":"lnbc210n1pzapinvoice"}"#.utf8)
        let zapRequest = try zapSigner.signZapRequest(
            recipientPubkey: String(repeating: "1", count: 64), relays: ["wss://relay.example"],
            amountMillisats: 21000)

        async let result = connection.payZap(
            lnurlPay: payResponse(),
            amountMillisats: 21000,
            zapRequest: zapRequest,
            urlSession: MockURLProtocol.makeSession())

        let request = try await NWCFixtures.waitForSentEvents(transport, count: 1)[0]
        await transport.emit(
            try NWCFixtures.response(
                resultJSON:
                    #"{"result_type":"pay_invoice","error":{"code":"PAYMENT_FAILED","message":"route not found"}}"#,
                requestID: request.id, client: client, wallet: wallet))

        do {
            _ = try await result
            Issue.record("expected a wallet error")
        } catch let WalletConnectError.walletError(code, message) {
            #expect(code == .paymentFailed)
            #expect(message == "route not found")
        }
    }

    @Test("payZap rejects an out-of-range amount before sending any wallet request")
    func payZapRejectsOutOfRange() async throws {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let zapSigner = EventSigner(keyPair: try KeyPair())
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)

        let zapRequest = try zapSigner.signZapRequest(
            recipientPubkey: String(repeating: "1", count: 64), relays: ["wss://relay.example"])

        await #expect(throws: LNURLPayResponse.InvoiceError.self) {
            _ = try await connection.payZap(
                lnurlPay: payResponse(),
                amountMillisats: 1,  // below minSendable
                zapRequest: zapRequest,
                urlSession: MockURLProtocol.makeSession())
        }
        #expect(await transport.sentEvents.isEmpty)
    }
}
