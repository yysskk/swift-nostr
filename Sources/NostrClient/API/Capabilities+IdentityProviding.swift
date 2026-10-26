import Foundation
import NostrCore

// MARK: - Conveniences

extension NostrIdentityProviding {
    /// Sets a local signer from a private key hex string. See ``NostrIdentityProviding/setSigner(_:)-(EventSigner)``.
    /// - Parameter privateKeyHex: The private key as 64 hex characters.
    /// - Throws: What ``EventSigner/init(privateKeyHex:)`` throws for a malformed key; the current
    ///   signer is then left in place.
    public func setPrivateKey(_ privateKeyHex: String) async throws {
        let signer = try EventSigner(privateKeyHex: privateKeyHex)
        await setSigner(signer)
    }

    /// Sets a local signer from a NIP-19 `nsec`. See ``NostrIdentityProviding/setSigner(_:)-(EventSigner)``.
    /// - Parameter nsec: The bech32-encoded private key.
    /// - Throws: What ``EventSigner/init(nsec:)`` throws for a malformed `nsec`; the current signer is
    ///   then left in place.
    public func setNsec(_ nsec: String) async throws {
        let signer = try EventSigner(nsec: nsec)
        await setSigner(signer)
    }
}
