import Foundation
import NostrCore

/// A ``NostrSigning`` that signs with a held key but is not an ``EventSigner`` and reports its
/// public key asynchronously — it stands in for a remote NIP-46 signer in targets that do not
/// depend on NostrConnect.
public struct StubRemoteSigner: NostrSigning {
    public let keyPair: KeyPair

    public init(keyPair: KeyPair) {
        self.keyPair = keyPair
    }

    public var publicKey: PublicKey {
        get async throws { keyPair.publicKey }
    }

    public func sign(_ event: UnsignedEvent) async throws -> Event {
        try EventSigner(keyPair: keyPair).sign(event)
    }

    public func sign(_ template: EventTemplate) async throws -> Event {
        try await sign(UnsignedEvent(template, publicKey: publicKey))
    }

    public func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Encrypt(plaintext, to: recipientPublicKey)
    }

    public func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        try EventSigner(keyPair: keyPair).nip44Decrypt(ciphertext, from: senderPublicKey)
    }
}
