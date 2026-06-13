import Foundation
import Testing

@testable import NostrClient

@Suite("NIP-57 Zap Request Tests")
struct NIP57ZapRequestTests {

    // MARK: - Zap request (kind 9734)

    @Test("signZapRequest builds a valid kind-9734 event")
    func signZapRequest() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signZapRequest(
            recipientPubkey: "recipienthex",
            relays: ["wss://relay1.example.com", "wss://relay2.example.com"],
            amountMillisats: 21000,
            lnurl: "lnurl1example",
            comment: "great post")

        #expect(event.kind == .zapRequest)
        #expect(event.content == "great post")
        #expect(event.referencedPubkeys == ["recipienthex"])
        #expect(event.firstTagValue(named: "amount") == "21000")
        #expect(event.firstTagValue(named: "lnurl") == "lnurl1example")
        #expect(
            event.tags(named: "relays").first?.values == [
                "wss://relay1.example.com", "wss://relay2.example.com",
            ])
        #expect(try event.verify())
    }

    @Test("signZapRequest tags the event when zapping a note")
    func zapRequestWithEvent() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signZapRequest(
            recipientPubkey: "rp", relays: ["wss://r.example.com"], eventId: "noteid")
        #expect(event.referencedEventIds == ["noteid"])
    }

    @Test("signZapRequest omits optional tags when not provided")
    func zapRequestMinimal() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signZapRequest(recipientPubkey: "rp", relays: ["wss://r.example.com"])

        #expect(event.firstTagValue(named: "amount") == nil)
        #expect(event.firstTagValue(named: "lnurl") == nil)
        #expect(event.referencedEventIds.isEmpty)
        #expect(event.content.isEmpty)
    }

    @Test("signZapRequest requires at least one relay")
    func zapRequestRequiresRelay() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        #expect(throws: NostrError.invalidData) {
            _ = try signer.signZapRequest(recipientPubkey: "rp", relays: [])
        }
    }

    @Test("signZapRequest tags an addressable event coordinate")
    func zapRequestWithCoordinate() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signZapRequest(
            recipientPubkey: "rp", relays: ["wss://r.example.com"],
            eventCoordinate: "30023:author:identifier")
        #expect(event.firstTagValue(named: "a") == "30023:author:identifier")
    }

    // MARK: - LNURL resolution

    @Test("a lightning address resolves to its LNURL-pay URL")
    func lightningAddressURL() {
        #expect(
            LNURL.payServiceURL(forLightningAddress: "alice@example.com")?.absoluteString
                == "https://example.com/.well-known/lnurlp/alice")
    }

    @Test("invalid lightning addresses return nil")
    func invalidLightningAddress() {
        #expect(LNURL.payServiceURL(forLightningAddress: "noatsign") == nil)
        #expect(LNURL.payServiceURL(forLightningAddress: "@example.com") == nil)
        #expect(LNURL.payServiceURL(forLightningAddress: "alice@") == nil)
    }

    @Test("a lightning address splits on the last @ (LUD-16)")
    func lightningAddressSplitsOnLastAt() throws {
        // The domain is the segment after the final "@", so the host can't be hijacked by an
        // earlier "@" in the name.
        let url = try #require(LNURL.payServiceURL(forLightningAddress: "user@host@example.com"))
        #expect(url.host == "example.com")
    }

    @Test("a lightning address name is percent-encoded to prevent path traversal")
    func lightningAddressEncodesName() throws {
        let url = try #require(LNURL.payServiceURL(forLightningAddress: "../../evil@example.com"))
        #expect(url.host == "example.com")
        // The "/" characters are escaped, so the name can't climb out of the lnurlp path segment.
        #expect(url.absoluteString.contains("%2F"))
        #expect(!url.absoluteString.contains("/../"))
    }

    @Test("a lightning address whose domain smuggles a path is rejected")
    func lightningAddressRejectsPathInDomain() {
        #expect(LNURL.payServiceURL(forLightningAddress: "alice@example.com/evil") == nil)
        #expect(LNURL.payServiceURL(forLightningAddress: "alice@example.com?x=1") == nil)
    }

    @Test("lnurl encodes and decodes round-trip")
    func lnurlRoundTrip() throws {
        let url = URL(string: "https://example.com/.well-known/lnurlp/alice")!
        let encoded = LNURL.encode(url)
        #expect(encoded.hasPrefix("lnurl1"))
        #expect(try LNURL.decode(encoded) == url)
    }

    @Test("decodes the LUD-06 lnurl test vector")
    func decodeKnownLnurl() throws {
        let lnurl =
            "LNURL1DP68GURN8GHJ7UM9WFMXJCM99E3K7MF0V9CXJ0M385EKVCENXC6R2C35XVUKXEFCV5MKVV34X5EKZD3EV56NYD3HXQURZEPEXEJXXEPNXSCRVWFNV9NXZCN9XQ6XYEFHVGCXXCMYXYMNSERXFQ5FNS"
        let url = try LNURL.decode(lnurl)
        #expect(
            url.absoluteString
                == "https://service.com/api?q=3fc3645b439ce8e7f2553a69e5267081d96dcd340693afabe04be7b0ccd178df")
    }

    // MARK: - LNURL-pay response

    @Test("decodes an LNURL-pay response and reports zap support")
    func decodePayResponse() throws {
        let json = """
            {"callback":"https://example.com/lnurl/cb","minSendable":1000,"maxSendable":100000000,
             "allowsNostr":true,"nostrPubkey":"abc123","commentAllowed":255,"tag":"payRequest"}
            """
        let response = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))

        #expect(response.callback == "https://example.com/lnurl/cb")
        #expect(response.minSendable == 1000)
        #expect(response.maxSendable == 100_000_000)
        #expect(response.commentAllowed == 255)
        #expect(response.supportsZaps)
    }

    @Test("a response without nostr support does not support zaps")
    func nonZapResponse() throws {
        let json = #"{"callback":"https://x.example.com/cb","minSendable":1000,"maxSendable":2000}"#
        let response = try JSONDecoder().decode(LNURLPayResponse.self, from: Data(json.utf8))
        #expect(!response.supportsZaps)
    }

    // MARK: - Invoice request URL

    @Test("builds the invoice request URL with amount, nostr, and lnurl params")
    func invoiceRequestURL() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        // A "+" in the comment exercises the strict query-value encoding.
        let zap = try signer.signZapRequest(
            recipientPubkey: "rp", relays: ["wss://r.example.com"], amountMillisats: 21000,
            comment: "tipping 1 + 1 sats")
        let response = LNURLPayResponse(
            callback: "https://example.com/cb", minSendable: 1000, maxSendable: 100_000,
            allowsNostr: true, nostrPubkey: "np")

        let url = try #require(
            response.invoiceRequestURL(amountMillisats: 21000, zapRequest: zap, lnurl: "lnurl1xyz"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })

        #expect(items["amount"] == "21000")
        #expect(items["lnurl"] == "lnurl1xyz")

        // The nostr param round-trips back to the exact signed zap request, "+" and all.
        let nostrJSON = try #require(items["nostr"] ?? nil)
        let decoded = try JSONDecoder().decode(Event.self, from: Data(nostrJSON.utf8))
        #expect(decoded.id == zap.id)
        #expect(decoded.kind == .zapRequest)
        #expect(decoded.content == "tipping 1 + 1 sats")
    }
}
