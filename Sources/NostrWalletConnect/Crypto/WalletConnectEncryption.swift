import NostrClient

/// A NIP-47 content-encryption scheme.
///
/// A wallet service advertises the schemes it supports in its info event's `encryption` tag, and a
/// request event names the scheme it used in its own `encryption` tag. The raw value is exactly the
/// token used on the wire.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public enum WalletConnectEncryption: String, Sendable, Hashable, CaseIterable {
    /// NIP-44 v2 (the preferred scheme).
    case nip44 = "nip44_v2"

    /// NIP-04 (legacy, deprecated — kept for backward compatibility).
    case nip04 = "nip04"
}

/// Encrypts and decrypts NIP-47 payloads with a chosen ``WalletConnectEncryption`` scheme.
///
/// NIP-44 reuses `NostrClient`'s `SealedMessage`; NIP-04 uses this module's ``NIP04``.
struct WalletConnectCipher: Sendable {
    /// The scheme this cipher applies.
    let scheme: WalletConnectEncryption

    init(_ scheme: WalletConnectEncryption) {
        self.scheme = scheme
    }

    /// Encrypts `plaintext` from `sender` to the holder of `recipientPubkey`.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPubkey: The recipient's 32-byte x-only public key (hex).
    ///   - sender: The sender's key pair.
    /// - Returns: The encrypted payload, in the chosen scheme's wire format.
    func encrypt(_ plaintext: String, recipientPubkey: String, sender: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try SealedMessage.seal(plaintext, for: recipientPubkey, using: sender).payload
        case .nip04:
            let peer = try xOnlyKey(recipientPubkey)
            return try NIP04.encrypt(plaintext, privateKey: sender.privateKey, peerPubkeyXOnly: peer)
        }
    }

    /// Decrypts `payload` sent by the holder of `senderPubkey` to `recipient`.
    /// - Parameters:
    ///   - payload: The encrypted payload, in the chosen scheme's wire format.
    ///   - senderPubkey: The sender's 32-byte x-only public key (hex).
    ///   - recipient: The recipient's key pair.
    /// - Returns: The decrypted plaintext.
    func decrypt(_ payload: String, senderPubkey: String, recipient: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try SealedMessage(payload: payload).open(from: senderPubkey, using: recipient)
        case .nip04:
            let peer = try xOnlyKey(senderPubkey)
            return try NIP04.decrypt(payload, privateKey: recipient.privateKey, peerPubkeyXOnly: peer)
        }
    }

    /// Decodes a 32-byte x-only public key from hex, or throws ``NostrError/invalidPublicKey``.
    private func xOnlyKey(_ hex: String) throws -> Data {
        guard let data = NWCHex.data(from: hex), data.count == 32 else {
            throw NostrError.invalidPublicKey
        }
        return data
    }
}
