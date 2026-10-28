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
/// NIP-44 reuses `NostrCore`'s `NIP44Payload`; NIP-04 uses this module's ``NIP04``.
struct WalletConnectCipher: Sendable {
    /// The scheme this cipher applies.
    let scheme: WalletConnectEncryption

    init(_ scheme: WalletConnectEncryption) {
        self.scheme = scheme
    }

    /// Encrypts `plaintext` from `sender` to the holder of `recipientPublicKey`.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    ///   - sender: The sender's key pair.
    /// - Returns: The encrypted payload, in the chosen scheme's wire format.
    func encrypt(_ plaintext: String, recipientPublicKey: PublicKey, sender: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try NIP44Payload.encrypt(plaintext, for: recipientPublicKey, using: sender).base64
        case .nip04:
            return try NIP04.encrypt(
                plaintext, privateKey: sender.privateKey, peerPublicKeyXOnly: recipientPublicKey.data)
        }
    }

    /// Decrypts `payload` sent by the holder of `senderPublicKey` to `recipient`.
    /// - Parameters:
    ///   - payload: The encrypted payload, in the chosen scheme's wire format.
    ///   - senderPublicKey: The sender's public key.
    ///   - recipient: The recipient's key pair.
    /// - Returns: The decrypted plaintext.
    func decrypt(_ payload: String, senderPublicKey: PublicKey, recipient: KeyPair) throws -> String {
        switch scheme {
        case .nip44:
            return try NIP44Payload(base64: payload).decrypt(from: senderPublicKey, using: recipient)
        case .nip04:
            return try NIP04.decrypt(
                payload, privateKey: recipient.privateKey, peerPublicKeyXOnly: senderPublicKey.data)
        }
    }
}
