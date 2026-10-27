import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

/// A relay from a pasted URI is connected to as written: `RelayConnection`'s URL-taking initializer
/// does not validate the scheme, unlike its string form. NostrConnect checks this on both its URI
/// types; NWC did not.
@Suite("Wallet Connect URI Scheme Tests")
struct WalletConnectURISchemeTests {
    private func uriString(relay: String) throws -> String {
        let wallet = KeyPair()
        let secret = KeyPair()
        let encoded =
            relay.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? relay
        return "nostr+walletconnect://\(wallet.publicKey.hex)?relay=\(encoded)&secret=\(secret.privateKey.hex)"
    }

    @Test(
        "a relay that is not a WebSocket URL is rejected",
        arguments: ["https://attacker.example", "http://attacker.example", "file:///etc/passwd"]
    )
    func nonWebSocketRelayIsRejected(relay: String) throws {
        #expect(throws: WalletConnectError.self) {
            _ = try WalletConnectURI(string: try uriString(relay: relay))
        }
    }

    @Test("ws and wss relays are accepted", arguments: ["wss://relay.example", "ws://relay.example"])
    func webSocketRelayIsAccepted(relay: String) throws {
        let uri = try WalletConnectURI(string: try uriString(relay: relay))
        #expect(uri.relays.count == 1)
    }
}
