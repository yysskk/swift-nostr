import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnectURI Tests")
struct WalletConnectURITests {
    // Canonical example from NIP-47.
    let walletKeyHex = "b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4"
    let secretHex = "71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"
    let canonical =
        "nostr+walletconnect://b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4"
        + "?relay=wss%3A%2F%2Frelay.damus.io"
        + "&secret=71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"

    @Test("parses the canonical NIP-47 connection string")
    func parseCanonical() throws {
        let uri = try WalletConnectURI(string: canonical)
        #expect(uri.walletPublicKey == (try PublicKey(hex: walletKeyHex)))
        #expect(uri.relays == [RelayURL("wss://relay.damus.io")!])
        #expect(uri.secret.hex == secretHex)
        #expect(uri.lud16 == nil)
    }

    @Test("keeps every relay when relay= is repeated, in order")
    func parseMultipleRelays() throws {
        let string =
            "nostr+walletconnect://\(walletKeyHex)"
            + "?relay=wss%3A%2F%2Frelay.one.example&relay=wss%3A%2F%2Frelay.two.example"
            + "&secret=\(secretHex)"
        let uri = try WalletConnectURI(string: string)
        #expect(
            uri.relays == [
                RelayURL("wss://relay.one.example")!,
                RelayURL("wss://relay.two.example")!,
            ])
    }

    @Test("parses an optional lud16 lightning address")
    func parseLUD16() throws {
        let uri = try WalletConnectURI(string: canonical + "&lud16=alice%40example.com")
        #expect(uri.lud16 == "alice@example.com")
    }

    @Test("round-trips through stringValue")
    func roundTrip() throws {
        let original = try WalletConnectURI(string: canonical + "&lud16=alice%40example.com")
        let reparsed = try WalletConnectURI(string: original.stringValue)
        #expect(reparsed == original)
    }

    @Test("derives the client identity from the secret")
    func clientIdentity() throws {
        let uri = try WalletConnectURI(string: canonical)
        let expected = try KeyPair(privateKey: PrivateKey(hex: secretHex))
        #expect(uri.clientKeyPair().publicKey == expected.publicKey)
        #expect(uri.clientPublicKey == expected.publicKey)
        #expect(uri.clientSigner().publicKey == expected.publicKey)
    }

    @Test("rejects a wrong scheme")
    func rejectsWrongScheme() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(string: "https://\(walletKeyHex)?relay=wss%3A%2F%2Fr.example&secret=\(secretHex)")
        }
    }

    @Test("rejects a non-32-byte-hex wallet public key")
    func rejectsBadPublicKey() {
        #expect(throws: WalletConnectError.invalidURI(reason: "wallet public key must be lowercase 32-byte hex")) {
            try WalletConnectURI(
                string: "nostr+walletconnect://deadbeef?relay=wss%3A%2F%2Fr.example&secret=\(secretHex)")
        }
    }

    /// A key has one spelling, so an uppercase host is rejected rather than folded to lowercase.
    @Test("rejects an uppercase wallet public key")
    func rejectsUppercasePublicKey() {
        #expect(throws: WalletConnectError.invalidURI(reason: "wallet public key must be lowercase 32-byte hex")) {
            try WalletConnectURI(
                string: "nostr+walletconnect://\(walletKeyHex.uppercased())"
                    + "?relay=wss%3A%2F%2Fr.example&secret=\(secretHex)")
        }
    }

    @Test("a URI built from typed components serializes its wallet key as the lowercase hex host")
    func typedComponentsRoundTrip() throws {
        let walletPublicKey = try PublicKey(hex: walletKeyHex)
        let uri = try WalletConnectURI(
            walletPublicKey: walletPublicKey,
            relays: [RelayURL("wss://relay.damus.io")!],
            secret: try PrivateKey(hex: secretHex))
        #expect(uri.stringValue.hasPrefix("nostr+walletconnect://\(walletKeyHex)?"))
        #expect(try WalletConnectURI(string: uri.stringValue).walletPublicKey == walletPublicKey)
    }

    @Test("rejects a missing relay")
    func rejectsMissingRelay() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(string: "nostr+walletconnect://\(walletKeyHex)?secret=\(secretHex)")
        }
    }

    @Test(
        "rejects a relay that is not a valid relay URL, even beside a valid one",
        arguments: [
            "https%3A%2F%2Frelay.example",  // not a WebSocket URL
            "wss%3A%2F%2Frelay.example%2F%23frag",  // fragment
            "wss%3A%2F%2Fuser%3Apw%40relay.example",  // user and password
            "wss%3A%2F%2F",  // empty host
        ])
    func rejectsMalformedRelay(relay: String) {
        let error = WalletConnectError.invalidURI(reason: "missing or malformed relay")
        #expect(throws: error) {
            try WalletConnectURI(string: "nostr+walletconnect://\(walletKeyHex)?relay=\(relay)&secret=\(secretHex)")
        }
        #expect(throws: error) {
            try WalletConnectURI(
                string: "nostr+walletconnect://\(walletKeyHex)?relay=wss%3A%2F%2Fgood.example&relay=\(relay)"
                    + "&secret=\(secretHex)")
        }
    }

    @Test("normalizes relays and writes them back in canonical form")
    func canonicalizesRelays() throws {
        let uri = try WalletConnectURI(
            string: "nostr+walletconnect://\(walletKeyHex)?relay=WSS%3A%2F%2FRelay.Damus.io%2F&secret=\(secretHex)")

        #expect(uri.relays == [RelayURL("wss://relay.damus.io")!])
        #expect(
            uri.stringValue == "nostr+walletconnect://\(walletKeyHex)?relay=wss://relay.damus.io&secret=\(secretHex)"
        )
    }

    @Test("rejects a malformed secret")
    func rejectsBadSecret() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(
                string: "nostr+walletconnect://\(walletKeyHex)?relay=wss%3A%2F%2Fr.example&secret=zz")
        }
    }

    @Test("rejects a too-short secret")
    func rejectsShortSecret() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(
                string: "nostr+walletconnect://\(walletKeyHex)?relay=wss%3A%2F%2Fr.example"
                    + "&secret=\(secretHex.prefix(32))")
        }
    }
}
