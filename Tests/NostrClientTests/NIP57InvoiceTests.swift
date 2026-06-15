import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-57 Invoice Retrieval Tests")
struct NIP57InvoiceTests {

    private func makePayResponse(min: Int64 = 1000, max: Int64 = 100_000_000) -> LNURLPayResponse {
        LNURLPayResponse(
            callback: "https://example.com/lnurl/cb", minSendable: min, maxSendable: max,
            allowsNostr: true, nostrPubkey: "np")
    }

    private func makeZapRequest() throws -> Event {
        let signer = EventSigner(keyPair: try KeyPair())
        return try signer.signZapRequest(
            recipientPubkey: "rp", relays: ["wss://r.example.com"], amountMillisats: 21000)
    }

    // MARK: - Success

    @Test("fetchInvoice returns the bolt11 and sends amount/nostr query params")
    func fetchInvoiceSuccess() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()
        let body = Data(#"{"pr":"lnbc210n1pjexample"}"#.utf8)

        let invocation = try await withMockURLSession(response: .success(status: 200, body: body)) { session in
            try await pay.fetchInvoice(
                amountMillisats: 21000, zapRequest: zap, lnurl: "lnurl1xyz", urlSession: session)
        }

        #expect(invocation.returnValue == "lnbc210n1pjexample")

        let request = try #require(invocation.request)
        #expect(request.httpMethod == "GET")
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(items["amount"] == "21000")
        #expect(items["nostr"] != nil)
        #expect(items["lnurl"] == "lnurl1xyz")
    }

    // MARK: - Amount validation

    @Test("fetchInvoice rejects an amount below minSendable before any network call")
    func fetchInvoiceAmountTooLow() async throws {
        let pay = makePayResponse(min: 10_000, max: 100_000)
        let zap = try makeZapRequest()

        // A failing transport proves the range guard fires first: we get amountOutOfRange, not networkError.
        await #expect(throws: LNURLPayResponse.InvoiceError.amountOutOfRange(min: 10_000, max: 100_000)) {
            _ = try await withMockURLSession(response: .failure(URLError(.cannotConnectToHost))) { session in
                try await pay.fetchInvoice(amountMillisats: 9_999, zapRequest: zap, urlSession: session)
            }
        }
    }

    @Test("fetchInvoice rejects an amount above maxSendable")
    func fetchInvoiceAmountTooHigh() async throws {
        let pay = makePayResponse(min: 10_000, max: 100_000)
        let zap = try makeZapRequest()

        await #expect(throws: LNURLPayResponse.InvoiceError.amountOutOfRange(min: 10_000, max: 100_000)) {
            _ = try await withMockURLSession(response: .failure(URLError(.cannotConnectToHost))) { session in
                try await pay.fetchInvoice(amountMillisats: 100_001, zapRequest: zap, urlSession: session)
            }
        }
    }

    @Test("fetchInvoice throws (not traps) when the endpoint advertises an inverted range")
    func fetchInvoiceInvertedRange() async throws {
        // A malformed response with minSendable > maxSendable must not trap on a range literal.
        let pay = makePayResponse(min: 100_000, max: 1000)
        let zap = try makeZapRequest()

        await #expect(throws: LNURLPayResponse.InvoiceError.amountOutOfRange(min: 100_000, max: 1000)) {
            _ = try await withMockURLSession(response: .failure(URLError(.cannotConnectToHost))) { session in
                try await pay.fetchInvoice(amountMillisats: 50_000, zapRequest: zap, urlSession: session)
            }
        }
    }

    // MARK: - Endpoint and response errors

    @Test("fetchInvoice surfaces an LNURL error body as lnurlError")
    func fetchInvoiceEndpointError() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()
        let body = Data(#"{"status":"ERROR","reason":"Amount too small"}"#.utf8)

        await #expect(throws: LNURLPayResponse.InvoiceError.lnurlError("Amount too small")) {
            _ = try await withMockURLSession(response: .success(status: 200, body: body)) { session in
                try await pay.fetchInvoice(amountMillisats: 21000, zapRequest: zap, urlSession: session)
            }
        }
    }

    @Test("fetchInvoice throws invalidResponse on a non-2xx status")
    func fetchInvoiceNon2xx() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()

        await #expect(throws: LNURLPayResponse.InvoiceError.invalidResponse) {
            _ = try await withMockURLSession(
                response: .success(status: 500, body: Data(#"{"pr":"lnbc1"}"#.utf8))
            ) { session in
                try await pay.fetchInvoice(amountMillisats: 21000, zapRequest: zap, urlSession: session)
            }
        }
    }

    @Test("fetchInvoice throws invalidResponse when the body has no invoice")
    func fetchInvoiceMissingInvoice() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()

        await #expect(throws: LNURLPayResponse.InvoiceError.invalidResponse) {
            _ = try await withMockURLSession(
                response: .success(status: 200, body: Data(#"{"foo":"bar"}"#.utf8))
            ) { session in
                try await pay.fetchInvoice(amountMillisats: 21000, zapRequest: zap, urlSession: session)
            }
        }
    }

    // MARK: - Transport errors

    @Test("fetchInvoice maps URLSession errors to networkError")
    func fetchInvoiceNetworkError() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()

        do {
            _ = try await withMockURLSession(response: .failure(URLError(.cannotConnectToHost))) { session in
                try await pay.fetchInvoice(amountMillisats: 21000, zapRequest: zap, urlSession: session)
            }
            Issue.record("Expected an error to be thrown")
        } catch let error as LNURLPayResponse.InvoiceError {
            guard case .networkError = error else {
                Issue.record("Unexpected InvoiceError: \(error)")
                return
            }
        }
    }

    @Test("fetchInvoice remaps URLError(.cancelled) to CancellationError")
    func fetchInvoiceCancellation() async throws {
        let pay = makePayResponse()
        let zap = try makeZapRequest()

        await #expect(throws: CancellationError.self) {
            _ = try await withMockURLSession(response: .failure(URLError(.cancelled))) { session in
                try await pay.fetchInvoice(amountMillisats: 21000, zapRequest: zap, urlSession: session)
            }
        }
    }
}
