import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrIdentityAPI`` that implements only the ``NostrIdentityProviding``
/// requirements, so a composed namespace can be exercised without a client.
actor RecordingIdentityCapabilities: NostrIdentityProviding {
    private(set) var authenticatedRelays: [RelayURL] = []
    private var signer: (any NostrSigning)?
    private var cachedPublicKey: PublicKey?
    private var mode: AuthenticationMode = .automatic

    // MARK: - NostrIdentityProviding

    func setSigner(_ signer: some NostrSigning) async throws {
        cachedPublicKey = try await signer.publicKey
        self.signer = signer
    }

    func removeSigner() async {
        signer = nil
        cachedPublicKey = nil
    }

    var publicKey: PublicKey? {
        cachedPublicKey
    }

    func sign(_ template: EventTemplate) async throws -> Event {
        try await requireSigner().sign(template)
    }

    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        try await requireSigner().nip44Encrypt(plaintext, to: recipientPublicKey)
    }

    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        try await requireSigner().nip44Decrypt(ciphertext, from: senderPublicKey)
    }

    var authenticationMode: AuthenticationMode {
        mode
    }

    func setAuthenticationMode(_ mode: AuthenticationMode) async {
        self.mode = mode
    }

    func authenticate(relayURL: RelayURL) async throws {
        authenticatedRelays.append(relayURL)
    }

    // MARK: - Private

    private func requireSigner() throws -> any NostrSigning {
        guard let signer else { throw NostrClient.Error.signerNotSet }
        return signer
    }
}
