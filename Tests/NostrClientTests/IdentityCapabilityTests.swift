import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// ``NostrIdentityProviding/setPrivateKey(_:)`` and ``NostrIdentityProviding/setNsec(_:)`` are
/// written once, in a protocol extension over ``NostrIdentityProviding/setSigner(_:)-(EventSigner)``.
/// Driving them through a stub that implements only the primitives shows which signer each installs,
/// through which overload, and that bad input throws before anything is installed.
@Suite("Identity Capability Tests")
struct IdentityCapabilityTests {
    /// The public keys of the local signers the stub installed, failing on any other installation.
    private func installedLocalKeys(_ stub: RecordingIdentityCapabilities) async -> [PublicKey] {
        await stub.installations.compactMap { installation in
            guard case .local(let signer) = installation else {
                Issue.record("expected the EventSigner overload of setSigner")
                return nil
            }
            return signer.publicKey
        }
    }

    @Test("setPrivateKey installs a local signer for that key through setSigner(EventSigner)")
    func setPrivateKeyInstallsALocalSigner() async throws {
        let stub = RecordingIdentityCapabilities()
        let identity: any NostrIdentityProviding = stub
        let keyPair = KeyPair()

        try await identity.setPrivateKey(keyPair.privateKey.hex)

        #expect(await installedLocalKeys(stub) == [keyPair.publicKey])
        #expect(await identity.publicKey == keyPair.publicKey)
        let signed = try await identity.sign(.textNote("signed"))
        #expect(signed.publicKey == keyPair.publicKey)
    }

    @Test("setNsec installs a local signer for that key through setSigner(EventSigner)")
    func setNsecInstallsALocalSigner() async throws {
        let stub = RecordingIdentityCapabilities()
        let identity: any NostrIdentityProviding = stub
        let keyPair = KeyPair()

        try await identity.setNsec(keyPair.privateKey.nsec)

        #expect(await installedLocalKeys(stub) == [keyPair.publicKey])
        #expect(await identity.publicKey == keyPair.publicKey)
    }

    @Test(
        "setPrivateKey throws EventSigner's error for a malformed key and keeps the current signer",
        arguments: [
            ("not hex", KeyPair.Error.invalidHex),
            (String(repeating: "0", count: 64), KeyPair.Error.invalidPrivateKey),
        ])
    func setPrivateKeyRejectsMalformedKeys(_ privateKeyHex: String, expected: KeyPair.Error) async throws {
        let stub = RecordingIdentityCapabilities()
        let identity: any NostrIdentityProviding = stub
        let current = KeyPair()
        try await identity.setPrivateKey(current.privateKey.hex)

        await #expect(throws: expected) {
            try await identity.setPrivateKey(privateKeyHex)
        }

        #expect(await installedLocalKeys(stub) == [current.publicKey])
        #expect(await identity.publicKey == current.publicKey)
    }

    @Test("setNsec throws EventSigner's error for a malformed nsec and keeps the current signer")
    func setNsecRejectsMalformedInput() async throws {
        let stub = RecordingIdentityCapabilities()
        let identity: any NostrIdentityProviding = stub
        let current = KeyPair()
        try await identity.setNsec(current.privateKey.nsec)
        let npub = current.publicKey.npub

        await #expect(throws: KeyPair.Error.unexpectedPrefix("npub")) {
            try await identity.setNsec(npub)
        }
        await #expect(throws: KeyPair.Error.invalidBech32(.invalidCharacter("b"))) {
            try await identity.setNsec("nsec1garbled")
        }

        #expect(await installedLocalKeys(stub) == [current.publicKey])
        #expect(await identity.publicKey == current.publicKey)
    }
}
