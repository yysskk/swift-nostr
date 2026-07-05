import Foundation
import NostrCore
import Testing

@Suite("LNURL Tests")
struct LNURLTests {

    // MARK: - Lightning Address Resolution

    @Test("Resolves a lightning address to its LNURL-pay service URL")
    func resolvesLightningAddress() {
        let url = LNURL.payServiceURL(forLightningAddress: "name@domain.com")

        #expect(url?.absoluteString == "https://domain.com/.well-known/lnurlp/name")
    }

    @Test("An address without an @ resolves to nil")
    func addressWithoutAtIsNil() {
        #expect(LNURL.payServiceURL(forLightningAddress: "nodomain") == nil)
    }

    @Test("An empty address resolves to nil")
    func emptyAddressIsNil() {
        #expect(LNURL.payServiceURL(forLightningAddress: "") == nil)
    }

    // MARK: - Bech32 lnurl Encoding

    @Test("Encoding then decoding round-trips a URL through the lnurl HRP")
    func encodeDecodeRoundTrip() throws {
        let url = try #require(URL(string: "https://example.com/.well-known/lnurlp/name"))

        let encoded = try LNURL.encode(url)
        #expect(encoded.lowercased().hasPrefix("lnurl1"))

        let decoded = try LNURL.decode(encoded)
        #expect(decoded == url)
    }

    // MARK: - LNURLPayResponse

    @Test("supportsZaps is true when the endpoint advertises Nostr and a pubkey")
    func supportsZapsWhenAdvertised() throws {
        let json = """
            {
                "callback": "https://example.com/lnurl/cb",
                "minSendable": 1000,
                "maxSendable": 100000000,
                "allowsNostr": true,
                "nostrPubkey": "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
            }
            """

        let response = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))

        #expect(response.callback == "https://example.com/lnurl/cb")
        #expect(response.minSendable == 1000)
        #expect(response.maxSendable == 100_000_000)
        #expect(response.supportsZaps)
    }

    @Test("supportsZaps is false without Nostr support")
    func doesNotSupportZapsWithoutNostr() throws {
        let json = """
            {
                "callback": "https://example.com/lnurl/cb",
                "minSendable": 1000,
                "maxSendable": 100000000
            }
            """

        let response = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))

        #expect(!response.supportsZaps)
    }

    @Test("invoiceRequestURL carries the amount and nostr query parameters")
    func invoiceRequestURLCarriesParameters() throws {
        let response = LNURLPayResponse(
            callback: "https://example.com/lnurl/cb",
            minSendable: 1000,
            maxSendable: 100_000_000,
            allowsNostr: true,
            nostrPubkey: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        )

        let recipient = try KeyPair()
        let signer = EventSigner(keyPair: try KeyPair())
        let zapRequest = try signer.signZapRequest(
            recipientPubkey: recipient.publicKeyHex,
            relays: ["wss://relay.example.com"],
            amountMillisats: 21000
        )

        let url = try #require(
            response.invoiceRequestURL(amountMillisats: 21000, zapRequest: zapRequest, lnurl: "lnurl1xyz"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(items["amount"] == "21000")
        #expect(items["nostr"] != nil)
        #expect(items["lnurl"] == "lnurl1xyz")
    }
}
