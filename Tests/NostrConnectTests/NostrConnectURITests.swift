import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("NostrConnectURI Tests")
struct NostrConnectURITests {
    let relays = [RelayURL("wss://relay.example")!]

    @Test("invitation adopts the key pair's public key and mints a hex secret")
    func invitationSetsPublicKeyAndSecret() throws {
        let keyPair = KeyPair()
        let invitation = try NostrConnectURI.invitation(
            clientKeyPair: keyPair,
            relays: relays,
            permissions: [.signEvent(kind: .textNote)]
        )

        #expect(invitation.clientPublicKey == keyPair.publicKey)
        #expect(!invitation.secret.isEmpty)
        #expect(Data(hexString: invitation.secret)?.count == 16)
    }

    @Test("two invitations get distinct secrets")
    func invitationsGetDistinctSecrets() throws {
        let keyPair = KeyPair()
        let first = try NostrConnectURI.invitation(clientKeyPair: keyPair, relays: relays)
        let second = try NostrConnectURI.invitation(clientKeyPair: keyPair, relays: relays)

        #expect(first.secret != second.secret)
    }

    @Test("round-trips with all metadata set")
    func roundTripsWithMetadata() throws {
        let keyPair = KeyPair()
        let invitation = try NostrConnectURI(
            clientPublicKey: keyPair.publicKey,
            relays: relays,
            secret: "deadbeef",
            permissions: [.signEvent(kind: .textNote), .nip44Encrypt],
            name: "My App",
            url: URL(string: "https://example.com"),
            image: URL(string: "https://example.com/icon.png")
        )

        #expect(try NostrConnectURI(string: invitation.stringValue) == invitation)
    }

    @Test("round-trips with metadata absent")
    func roundTripsWithoutMetadata() throws {
        let keyPair = KeyPair()
        let invitation = try NostrConnectURI.invitation(clientKeyPair: keyPair, relays: relays)

        let parsed = try NostrConnectURI(string: invitation.stringValue)
        #expect(parsed == invitation)
        #expect(parsed.permissions.isEmpty)
        #expect(parsed.name == nil)
        #expect(parsed.url == nil)
        #expect(parsed.image == nil)
    }

    @Test("percent-encoded metadata survives the round-trip")
    func encodedMetadataSurvivesRoundTrip() throws {
        let keyPair = KeyPair()
        let invitation = try NostrConnectURI(
            clientPublicKey: keyPair.publicKey,
            relays: relays,
            secret: "s3cr3t",
            name: "My App & Co",
            url: URL(string: "https://example.com/path?q=a%20b"),
            image: URL(string: "https://example.com/i.png?v=1&size=2")
        )

        let parsed = try NostrConnectURI(string: invitation.stringValue)
        #expect(parsed.name == "My App & Co")
        #expect(parsed.url == URL(string: "https://example.com/path?q=a%20b"))
        #expect(parsed.image == URL(string: "https://example.com/i.png?v=1&size=2"))
    }

    @Test("rejects a token with no secret")
    func rejectsMissingSecret() throws {
        let keyPair = KeyPair()
        #expect(throws: RemoteSignerError.self) {
            try NostrConnectURI(string: "nostrconnect://\(keyPair.publicKey.hex)?relay=wss%3A%2F%2Frelay.example")
        }
    }

    @Test("rejects a malformed public key")
    func rejectsMalformedPublicKey() {
        #expect(throws: RemoteSignerError.invalidURI(reason: "client public key must be lowercase 32-byte hex")) {
            try NostrConnectURI(string: "nostrconnect://zzzz?relay=wss%3A%2F%2Frelay.example&secret=s")
        }
    }

    /// A key has one spelling, so an uppercase host is rejected rather than folded to lowercase.
    @Test("rejects an uppercase public key")
    func rejectsUppercasePublicKey() throws {
        let publicKey = KeyPair().publicKey.hex.uppercased()
        #expect(throws: RemoteSignerError.invalidURI(reason: "client public key must be lowercase 32-byte hex")) {
            try NostrConnectURI(string: "nostrconnect://\(publicKey)?relay=wss%3A%2F%2Frelay.example&secret=s")
        }
    }

    @Test("serializes the typed client key as the lowercase hex host and parses it back")
    func serializesTypedKeyAsHost() throws {
        let keyPair = KeyPair()
        let invitation = try NostrConnectURI(clientPublicKey: keyPair.publicKey, relays: relays, secret: "s")

        let expected = "nostrconnect://\(keyPair.publicKey.hex)?relay=wss%3A%2F%2Frelay.example&secret=s"
        #expect(invitation.stringValue == expected)
        #expect(try NostrConnectURI(string: invitation.stringValue).clientPublicKey == keyPair.publicKey)
    }

    @Test(
        "rejects a relay that is not a valid relay URL, even beside a valid one",
        arguments: [
            "https%3A%2F%2Frelay.example",  // not a WebSocket URL
            "wss%3A%2F%2Frelay.example%2F%23frag",  // fragment
            "wss%3A%2F%2Fuser%3Apw%40relay.example",  // user and password
            "wss%3A%2F%2F",  // empty host
        ])
    func rejectsMalformedRelay(relay: String) throws {
        let publicKey = KeyPair().publicKey.hex
        let error = RemoteSignerError.invalidURI(reason: "missing or malformed relay")
        #expect(throws: error) {
            try NostrConnectURI(string: "nostrconnect://\(publicKey)?relay=\(relay)&secret=s")
        }
        #expect(throws: error) {
            try NostrConnectURI(
                string: "nostrconnect://\(publicKey)?relay=wss%3A%2F%2Fgood.example&relay=\(relay)&secret=s")
        }
    }

    @Test("normalizes relays and writes them back in canonical form")
    func canonicalizesRelays() throws {
        let publicKey = KeyPair().publicKey.hex
        let uri = try NostrConnectURI(string: "nostrconnect://\(publicKey)?relay=WSS%3A%2F%2FRelay.Example%2F&secret=s")

        #expect(uri.relays == [RelayURL("wss://relay.example")!])
        #expect(uri.stringValue == "nostrconnect://\(publicKey)?relay=wss%3A%2F%2Frelay.example&secret=s")
    }

    @Test("parses a comma-separated permission list")
    func parsesPermissionList() throws {
        let keyPair = KeyPair()
        let uri = try NostrConnectURI(
            string:
                "nostrconnect://\(keyPair.publicKey.hex)?relay=wss%3A%2F%2Frelay.example&secret=s&perms=sign_event%3A1%2Cnip44_encrypt"
        )

        #expect(
            uri.permissions.map(\.rawValue) == [
                RemoteSignerPermission.signEvent(kind: .textNote).rawValue,
                RemoteSignerPermission.nip44Encrypt.rawValue,
            ]
        )
    }
}
