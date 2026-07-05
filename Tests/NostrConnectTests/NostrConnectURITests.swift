import Foundation
import NostrCore
import Testing

@testable import NostrConnect

@Suite("NostrConnectURI Tests")
struct NostrConnectURITests {
    let relays = [URL(string: "wss://relay.example")!]

    @Test("invitation adopts the key pair's pubkey and mints a hex secret")
    func invitationSetsPubkeyAndSecret() throws {
        let keyPair = try KeyPair()
        let invitation = try NostrConnectURI.invitation(
            clientKeyPair: keyPair,
            relays: relays,
            permissions: [.signEvent(kind: .textNote)]
        )

        #expect(invitation.clientPubkey == keyPair.publicKeyHex)
        #expect(!invitation.secret.isEmpty)
        #expect(Data(hexString: invitation.secret)?.count == 16)
    }

    @Test("two invitations get distinct secrets")
    func invitationsGetDistinctSecrets() throws {
        let keyPair = try KeyPair()
        let first = try NostrConnectURI.invitation(clientKeyPair: keyPair, relays: relays)
        let second = try NostrConnectURI.invitation(clientKeyPair: keyPair, relays: relays)

        #expect(first.secret != second.secret)
    }

    @Test("round-trips with all metadata set")
    func roundTripsWithMetadata() throws {
        let keyPair = try KeyPair()
        let invitation = try NostrConnectURI(
            clientPubkey: keyPair.publicKeyHex,
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
        let keyPair = try KeyPair()
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
        let keyPair = try KeyPair()
        let invitation = try NostrConnectURI(
            clientPubkey: keyPair.publicKeyHex,
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
        let keyPair = try KeyPair()
        #expect(throws: RemoteSignerError.self) {
            try NostrConnectURI(string: "nostrconnect://\(keyPair.publicKeyHex)?relay=wss%3A%2F%2Frelay.example")
        }
    }

    @Test("rejects a malformed pubkey")
    func rejectsMalformedPubkey() {
        #expect(throws: RemoteSignerError.self) {
            try NostrConnectURI(string: "nostrconnect://zzzz?relay=wss%3A%2F%2Frelay.example&secret=s")
        }
    }

    @Test("parses a comma-separated permission list")
    func parsesPermissionList() throws {
        let keyPair = try KeyPair()
        let uri = try NostrConnectURI(
            string:
                "nostrconnect://\(keyPair.publicKeyHex)?relay=wss%3A%2F%2Frelay.example&secret=s&perms=sign_event%3A1%2Cnip44_encrypt"
        )

        #expect(
            uri.permissions.map(\.rawValue) == [
                RemoteSignerPermission.signEvent(kind: .textNote).rawValue,
                RemoteSignerPermission.nip44Encrypt.rawValue,
            ]
        )
    }
}
