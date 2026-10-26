import NostrCore

/// A signer whose every operation throws ``NostrError/timeout``, proving a code path never
/// reaches it — or that its errors propagate.
struct FailingSigner: NostrSigning {
    var publicKey: PublicKey {
        get async throws { throw NostrError.timeout }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        throw NostrError.timeout
    }

    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        throw NostrError.timeout
    }

    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        throw NostrError.timeout
    }
}
