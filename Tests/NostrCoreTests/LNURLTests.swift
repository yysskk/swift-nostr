import Foundation
import NostrCore
import NostrTestSupport
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

        let encoded = LNURL.encode(url)
        #expect(encoded.lowercased().hasPrefix("lnurl1"))

        let decoded = try LNURL.decode(encoded)
        #expect(decoded == url)
    }

    @Test("Decoding reports why a string is not an lnurl")
    func decodeFailureReasons() throws {
        let npub = KeyPair().publicKey.npub
        let notUTF8 = try Bech32.encode(hrp: "lnurl", data: Data([0xff, 0xfe]))

        #expect(throws: LNURL.Error.invalidBech32(.missingSeparator)) {
            try LNURL.decode("lnurl")
        }
        #expect(throws: LNURL.Error.unexpectedPrefix("npub")) {
            try LNURL.decode(npub)
        }
        #expect(throws: LNURL.Error.invalidURL) {
            try LNURL.decode(notUTF8)
        }
    }

    // MARK: - LNURLPayResponse

    @Test("supportsZaps is true when the endpoint advertises Nostr and a public key")
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

        #expect(response.callback == URL(string: "https://example.com/lnurl/cb"))
        #expect(response.minimumSendable == 1000)
        #expect(response.maximumSendable == 100_000_000)
        #expect(response.nostrPublicKey?.hex == "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d")
        #expect(response.supportsZaps)
    }

    /// The response comes from a third-party endpoint: a malformed key must not cost the caller the
    /// rest of it, but it must not count as a key receipts can be checked against either.
    @Test(
        "a malformed nostrPublicKey decodes as nil and disables zaps",
        arguments: [
            #""nostrPubkey": "abc123""#,
            #""nostrPubkey": "3BF0C63FCB93463407AF97A5E5EE64FA883D107EF9E558472C4EB9AAAEFA459D""#,
            #""nostrPubkey": 42"#,
        ])
    func malformedNostrPublicKeyIsDropped(field: String) throws {
        let json = """
            {
                "callback": "https://example.com/lnurl/cb",
                "minSendable": 1000,
                "maxSendable": 100000000,
                "allowsNostr": true,
                \(field)
            }
            """

        let response = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))

        #expect(response.callback == URL(string: "https://example.com/lnurl/cb"))
        #expect(response.allowsNostr == true)
        #expect(response.nostrPublicKey == nil)
        #expect(!response.supportsZaps)
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

    /// Without a usable callback there is nowhere to request an invoice, so the response is rejected
    /// as a whole rather than decoded into a value that can never be paid.
    @Test("a callback that is not a URL fails the decode", arguments: ["", "http://[::1"])
    func invalidCallbackFails(callback: String) {
        let json = #"{"callback": "\#(callback)", "minSendable": 1000, "maxSendable": 100000000}"#

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))
        }
    }

    @Test("invoiceRequestURL carries the amount and nostr query parameters")
    func invoiceRequestURLCarriesParameters() throws {
        let response = LNURLPayResponse(
            callback: URL(string: "https://example.com/lnurl/cb")!,
            minimumSendable: 1000,
            maximumSendable: 100_000_000,
            allowsNostr: true,
            nostrPublicKey: .fixture("provider")
        )

        let recipient = KeyPair()
        let signer = EventSigner(keyPair: KeyPair())
        let zapRequest = try signer.sign(
            .zapRequest(
                to: recipient.publicKey,
                relays: [RelayURL("wss://relay.example.com")!],
                amountMillisats: 21000
            ))

        let url = try #require(
            response.invoiceRequestURL(amountMillisats: 21000, zapRequest: zapRequest, lnurl: "lnurl1xyz"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(items["amount"] == "21000")
        #expect(items["nostr"] != nil)
        #expect(items["lnurl"] == "lnurl1xyz")
    }
}
