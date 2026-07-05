import Foundation
import Testing

@testable import NostrConnect

@Suite("BunkerURI Tests")
struct BunkerURITests {
    // A remote signer pubkey (32-byte hex, secp256k1 generator x-coordinate).
    let pubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

    @Test("parses a spec-shaped token")
    func parsesSpecShapedToken() throws {
        let uri = try BunkerURI(string: "bunker://\(pubkey)?relay=wss%3A%2F%2Frelay.example&secret=abc123")

        #expect(uri.remoteSignerPubkey == pubkey)
        #expect(uri.relays == [URL(string: "wss://relay.example")!])
        #expect(uri.secret == "abc123")
    }

    @Test("captures multiple relay parameters")
    func capturesMultipleRelays() throws {
        let uri = try BunkerURI(
            string: "bunker://\(pubkey)?relay=wss%3A%2F%2Frelay.one&relay=wss%3A%2F%2Frelay.two&secret=s"
        )

        #expect(
            uri.relays == [
                URL(string: "wss://relay.one")!,
                URL(string: "wss://relay.two")!,
            ]
        )
    }

    @Test("parses a token without a secret")
    func parsesTokenWithoutSecret() throws {
        let uri = try BunkerURI(string: "bunker://\(pubkey)?relay=wss%3A%2F%2Frelay.example")

        #expect(uri.secret == nil)
    }

    @Test("rejects a token with no relay")
    func rejectsMissingRelay() {
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "bunker://\(pubkey)?secret=abc123")
        }
    }

    @Test("rejects a malformed pubkey")
    func rejectsMalformedPubkey() {
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "bunker://zzzz?relay=wss%3A%2F%2Frelay.example")
        }
    }

    @Test("rejects the wrong scheme")
    func rejectsWrongScheme() {
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "nostrconnect://\(pubkey)?relay=wss%3A%2F%2Frelay.example")
        }
    }

    @Test("rejects a non-WebSocket relay")
    func rejectsNonWebSocketRelay() {
        // Relay values come from an untrusted signer/QR code; only ws:// and wss:// are accepted.
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "bunker://\(pubkey)?relay=https%3A%2F%2Frelay.example")
        }
    }

    @Test("round-trips through stringValue with a secret")
    func roundTripsWithSecret() throws {
        let uri = try BunkerURI(
            remoteSignerPubkey: pubkey,
            relays: [URL(string: "wss://relay.one")!, URL(string: "wss://relay.two")!],
            secret: "abc123"
        )

        #expect(try BunkerURI(string: uri.stringValue) == uri)
    }

    @Test("round-trips through stringValue without a secret")
    func roundTripsWithoutSecret() throws {
        let uri = try BunkerURI(
            remoteSignerPubkey: pubkey,
            relays: [URL(string: "wss://relay.example")!]
        )

        #expect(try BunkerURI(string: uri.stringValue) == uri)
    }
}
