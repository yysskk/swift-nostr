import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("BunkerURI Tests")
struct BunkerURITests {
    // A remote signer public key (32-byte hex, secp256k1 generator x-coordinate).
    let publicKey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    let malformedPublicKeyError = RemoteSignerError.invalidURI(
        reason: "remote signer public key must be lowercase 32-byte hex")

    @Test("parses a spec-shaped token")
    func parsesSpecShapedToken() throws {
        let uri = try BunkerURI(string: "bunker://\(publicKey)?relay=wss%3A%2F%2Frelay.example&secret=abc123")

        #expect(uri.remoteSignerPublicKey == (try PublicKey(hex: publicKey)))
        #expect(uri.relays == [RelayURL("wss://relay.example")!])
        #expect(uri.secret == "abc123")
    }

    @Test("captures multiple relay parameters")
    func capturesMultipleRelays() throws {
        let uri = try BunkerURI(
            string: "bunker://\(publicKey)?relay=wss%3A%2F%2Frelay.one&relay=wss%3A%2F%2Frelay.two&secret=s"
        )

        #expect(
            uri.relays == [
                RelayURL("wss://relay.one")!,
                RelayURL("wss://relay.two")!,
            ]
        )
    }

    @Test("parses a token without a secret")
    func parsesTokenWithoutSecret() throws {
        let uri = try BunkerURI(string: "bunker://\(publicKey)?relay=wss%3A%2F%2Frelay.example")

        #expect(uri.secret == nil)
    }

    @Test("rejects a token with no relay")
    func rejectsMissingRelay() {
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "bunker://\(publicKey)?secret=abc123")
        }
    }

    @Test("rejects a malformed public key")
    func rejectsMalformedPublicKey() {
        #expect(throws: malformedPublicKeyError) {
            try BunkerURI(string: "bunker://zzzz?relay=wss%3A%2F%2Frelay.example")
        }
    }

    /// A key has one spelling, so an uppercase host is rejected rather than folded to lowercase.
    @Test("rejects an uppercase public key")
    func rejectsUppercasePublicKey() {
        #expect(throws: malformedPublicKeyError) {
            try BunkerURI(string: "bunker://\(publicKey.uppercased())?relay=wss%3A%2F%2Frelay.example")
        }
    }

    @Test("rejects the wrong scheme")
    func rejectsWrongScheme() {
        #expect(throws: RemoteSignerError.self) {
            try BunkerURI(string: "nostrconnect://\(publicKey)?relay=wss%3A%2F%2Frelay.example")
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
        // Relay values come from an untrusted signer/QR code; a malformed one is an error rather
        // than silently dropped.
        let error = RemoteSignerError.invalidURI(reason: "missing or malformed relay")
        #expect(throws: error) {
            try BunkerURI(string: "bunker://\(publicKey)?relay=\(relay)")
        }
        #expect(throws: error) {
            try BunkerURI(string: "bunker://\(publicKey)?relay=wss%3A%2F%2Fgood.example&relay=\(relay)")
        }
    }

    @Test("normalizes relays and writes them back in canonical form")
    func canonicalizesRelays() throws {
        let uri = try BunkerURI(string: "bunker://\(publicKey)?relay=WSS%3A%2F%2FRelay.Example%3A443%2F")

        #expect(uri.relays == [RelayURL("wss://relay.example")!])
        #expect(uri.stringValue == "bunker://\(publicKey)?relay=wss%3A%2F%2Frelay.example")
    }

    @Test("round-trips through stringValue with a secret")
    func roundTripsWithSecret() throws {
        let uri = try BunkerURI(
            remoteSignerPublicKey: try PublicKey(hex: publicKey),
            relays: [RelayURL("wss://relay.one")!, RelayURL("wss://relay.two")!],
            secret: "abc123"
        )

        #expect(try BunkerURI(string: uri.stringValue) == uri)
    }

    @Test("round-trips through stringValue without a secret")
    func roundTripsWithoutSecret() throws {
        let uri = try BunkerURI(
            remoteSignerPublicKey: try PublicKey(hex: publicKey),
            relays: [RelayURL("wss://relay.example")!]
        )

        #expect(try BunkerURI(string: uri.stringValue) == uri)
    }

    @Test("serializes a typed signer key as the lowercase hex host")
    func serializesTypedKeyAsHost() throws {
        let uri = try BunkerURI(
            remoteSignerPublicKey: try PublicKey(hex: publicKey),
            relays: [RelayURL("wss://relay.example")!],
            secret: "abc123"
        )

        #expect(uri.stringValue == "bunker://\(publicKey)?relay=wss%3A%2F%2Frelay.example&secret=abc123")
    }
}
