import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnectURI Tests")
struct WalletConnectURITests {
    // Canonical example from NIP-47.
    let walletPubkey = "b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4"
    let secretHex = "71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"
    let canonical =
        "nostr+walletconnect://b889ff5b1513b641e2a139f661a661364979c5beee91842f8f0ef42ab558e9d4"
        + "?relay=wss%3A%2F%2Frelay.damus.io"
        + "&secret=71a8c14c1407c113601079c4302dab36460f0ccd0ad506f1f2dc73b5100e4f3c"

    @Test("parses the canonical NIP-47 connection string")
    func parseCanonical() throws {
        let uri = try WalletConnectURI(string: canonical)
        #expect(uri.walletPubkey == walletPubkey)
        #expect(uri.relays == [URL(string: "wss://relay.damus.io")!])
        #expect(NWCHex.string(from: uri.secret) == secretHex)
        #expect(uri.lud16 == nil)
    }

    @Test("keeps every relay when relay= is repeated, in order")
    func parseMultipleRelays() throws {
        let string =
            "nostr+walletconnect://\(walletPubkey)"
            + "?relay=wss%3A%2F%2Frelay.one.example&relay=wss%3A%2F%2Frelay.two.example"
            + "&secret=\(secretHex)"
        let uri = try WalletConnectURI(string: string)
        #expect(
            uri.relays == [
                URL(string: "wss://relay.one.example")!,
                URL(string: "wss://relay.two.example")!,
            ])
    }

    @Test("parses an optional lud16 lightning address")
    func parseLud16() throws {
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
        let expected = try KeyPair(privateKeyHex: secretHex)
        #expect(uri.clientKeyPair().publicKeyHex == expected.publicKeyHex)
        #expect(uri.clientPublicKeyHex == expected.publicKeyHex)
        #expect(uri.clientSigner().publicKey == expected.publicKeyHex)
    }

    @Test("rejects a wrong scheme")
    func rejectsWrongScheme() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(string: "https://\(walletPubkey)?relay=wss%3A%2F%2Fr.example&secret=\(secretHex)")
        }
    }

    @Test("rejects a non-32-byte-hex wallet pubkey")
    func rejectsBadPubkey() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(
                string: "nostr+walletconnect://deadbeef?relay=wss%3A%2F%2Fr.example&secret=\(secretHex)")
        }
    }

    @Test("rejects a missing relay")
    func rejectsMissingRelay() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(string: "nostr+walletconnect://\(walletPubkey)?secret=\(secretHex)")
        }
    }

    @Test("rejects a malformed secret")
    func rejectsBadSecret() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(string: "nostr+walletconnect://\(walletPubkey)?relay=wss%3A%2F%2Fr.example&secret=zz")
        }
    }

    @Test("rejects a too-short secret")
    func rejectsShortSecret() {
        #expect(throws: WalletConnectError.self) {
            try WalletConnectURI(
                walletPubkey: walletPubkey,
                relays: [URL(string: "wss://r.example")!],
                secret: Data(repeating: 1, count: 16))
        }
    }
}
