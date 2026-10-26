import Foundation
import NostrCore

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
/// NIP-44 reuses `NostrCore`'s `SealedMessage`; NIP-04 uses this module's ``NIP04``.
struct WalletConnectCipher: Sendable {
    /// The scheme this cipher applies.
    let scheme: WalletConnectEncryption

    init(_ scheme: WalletConnectEncryption) {
        self.scheme = scheme
    }

    /// Encrypts `plaintext` from `sender` to the holder of `recipientPubkey`.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPubkey: The recipient's public key.
    ///   - sender: The sender's key pair.
    /// - Returns: The encrypted payload, in the chosen scheme's wire format.
    func encrypt(_ plaintext: String, recipientPubkey: PublicKey, sender: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try SealedMessage.seal(plaintext, for: recipientPubkey, using: sender).payload
        case .nip04:
            return try NIP04.encrypt(plaintext, privateKey: sender.privateKey, peerPubkeyXOnly: recipientPubkey.data)
        }
    }

    /// Decrypts `payload` sent by the holder of `senderPubkey` to `recipient`.
    /// - Parameters:
    ///   - payload: The encrypted payload, in the chosen scheme's wire format.
    ///   - senderPubkey: The sender's public key.
    ///   - recipient: The recipient's key pair.
    /// - Returns: The decrypted plaintext.
    func decrypt(_ payload: String, senderPubkey: PublicKey, recipient: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try SealedMessage(payload: payload).open(from: senderPubkey, using: recipient)
        case .nip04:
            return try NIP04.decrypt(payload, privateKey: recipient.privateKey, peerPubkeyXOnly: senderPubkey.data)
        }
    }
}
