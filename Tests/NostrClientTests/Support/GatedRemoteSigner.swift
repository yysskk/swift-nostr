import Foundation
import NostrCore
import NostrTestSupport

/// Holds every ``GatedRemoteSigner/publicKey`` lookup until the test opens it, and lets the test
/// wait until a lookup has started, so overlapping signer installs can be ordered without sleeps.
actor PublicKeyGate {
    private var isOpen = false
    private var isRequested = false
    private var lookups: [CheckedContinuation<Void, Never>] = []
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    /// Suspends a lookup until ``open()``, first waking anyone parked in ``untilRequested()``.
    func pass() async {
        isRequested = true
        for waiter in requestWaiters { waiter.resume() }
        requestWaiters.removeAll()
        guard !isOpen else { return }
        await withCheckedContinuation { lookups.append($0) }
    }

    /// Returns once a lookup has reached the gate.
    func untilRequested() async {
        guard !isRequested else { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    /// Releases every held lookup and lets later ones through.
    func open() {
        isOpen = true
        for lookup in lookups { lookup.resume() }
        lookups.removeAll()
    }
}

/// A ``StubRemoteSigner`` whose public key resolves only once its ``PublicKeyGate`` opens.
struct GatedRemoteSigner: NostrSigning {
    let keyPair: KeyPair
    let gate: PublicKeyGate

    var publicKey: PublicKey {
        get async throws {
            await gate.pass()
            return keyPair.publicKey
        }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        try await StubRemoteSigner(keyPair: keyPair).sign(event)
    }

    func sign(_ template: EventTemplate) async throws -> Event {
        try await StubRemoteSigner(keyPair: keyPair).sign(template)
    }

    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        try await StubRemoteSigner(keyPair: keyPair).nip44Encrypt(plaintext, to: recipientPublicKey)
    }

    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        try await StubRemoteSigner(keyPair: keyPair).nip44Decrypt(ciphertext, from: senderPublicKey)
    }
}
