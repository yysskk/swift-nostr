import NostrCore

/// A signer whose every operation throws ``RelayConnection/Error/timedOut``, proving a code path never
/// reaches it — or that its errors propagate.
struct FailingSigner: NostrSigning {
    var publicKey: PublicKey {
        get async throws { throw RelayConnection.Error.timedOut }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        throw RelayConnection.Error.timedOut
    }

    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        throw RelayConnection.Error.timedOut
    }

    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        throw RelayConnection.Error.timedOut
    }
}
