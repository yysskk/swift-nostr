import Crypto
import Foundation
import P256K
import _CryptoExtras

/// NIP-04 encryption: AES-256-CBC over a secp256k1 ECDH shared secret.
///
/// NIP-04 is the legacy encryption for NIP-47 wallet messages. It is deprecated in favor of NIP-44,
/// but many wallet services still require it, so it is supported for backward compatibility.
///
/// The AES key is the **X coordinate of the ECDH shared point, used directly** — unlike NIP-44,
/// NIP-04 does not run it through a KDF. The encrypted content is wire-encoded as
/// `"<base64 ciphertext>?iv=<base64 iv>"` with a random 16-byte IV and PKCS#7 padding.
/// https://github.com/nostr-protocol/nips/blob/master/04.md
enum NIP04 {
    /// The reason NIP-04 content could not be decrypted.
    enum DecodingError: Error, Equatable {
        /// The content was not of the form `"<ciphertext>?iv=<iv>"`.
        case malformedContent
        /// The ciphertext or IV was not valid base64.
        case invalidBase64
        /// The decrypted bytes were not valid UTF-8.
        case invalidUTF8
    }

    /// Derives the AES-256 key for a NIP-04 conversation: the X coordinate of the secp256k1 ECDH
    /// shared point. NIP-04 uses this raw value as the key (no HKDF), which is what distinguishes it
    /// from NIP-44.
    /// - Parameters:
    ///   - privateKey: The local 32-byte private key.
    ///   - peerPubkeyXOnly: The peer's 32-byte x-only public key.
    static func sharedKey(privateKey: Data, peerPubkeyXOnly: Data) throws -> SymmetricKey {
        let agreementKey = try P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey)
        let publicKey = try liftXOnly(peerPubkeyXOnly)
        let sharedSecret = agreementKey.sharedSecretFromKeyAgreement(with: publicKey, format: .compressed)
        // The compressed shared point is `parity (1 byte) || X (32 bytes)`; NIP-04 keys on the bare X.
        let sharedX = sharedSecret.withUnsafeBytes { Data($0.dropFirst()) }
        return SymmetricKey(data: sharedX)
    }

    /// Encrypts `plaintext` for `peerPubkeyXOnly`.
    /// - Returns: NIP-04 content `"<base64 ciphertext>?iv=<base64 iv>"` with a random IV.
    static func encrypt(_ plaintext: String, privateKey: Data, peerPubkeyXOnly: Data) throws -> String {
        let key = try sharedKey(privateKey: privateKey, peerPubkeyXOnly: peerPubkeyXOnly)
        let iv = AES._CBC.IV()
        let ciphertext = try AES._CBC.encrypt(Array(plaintext.utf8), using: key, iv: iv)
        return ciphertext.base64EncodedString() + "?iv=" + Data(iv).base64EncodedString()
    }

    /// Decrypts NIP-04 content of the form `"<base64 ciphertext>?iv=<base64 iv>"`.
    /// - Throws: ``DecodingError`` if the content is malformed, or a crypto error if the key/IV are
    ///   rejected.
    static func decrypt(_ content: String, privateKey: Data, peerPubkeyXOnly: Data) throws -> String {
        let parts = content.components(separatedBy: "?iv=")
        guard parts.count == 2 else {
            throw DecodingError.malformedContent
        }
        guard let ciphertext = Data(base64Encoded: parts[0]),
            let ivData = Data(base64Encoded: parts[1])
        else {
            throw DecodingError.invalidBase64
        }
        // The IV is part of the wire format, so a wrong length is malformed content — surface it as
        // a DecodingError rather than letting AES._CBC.IV throw a raw crypto error.
        guard ivData.count == 16 else {
            throw DecodingError.malformedContent
        }

        let key = try sharedKey(privateKey: privateKey, peerPubkeyXOnly: peerPubkeyXOnly)
        let iv = try AES._CBC.IV(ivBytes: ivData)
        let plaintextData = try AES._CBC.decrypt(ciphertext, using: key, iv: iv)
        guard let plaintext = String(data: plaintextData, encoding: .utf8) else {
            throw DecodingError.invalidUTF8
        }
        return plaintext
    }

    /// Reconstructs a full public key from a 32-byte x-only key, assuming even Y (the BIP-340 /
    /// NIP-04 convention). Odd Y is tried only as a defensive fallback; for a valid on-curve X the
    /// even-Y point always exists.
    private static func liftXOnly(_ xOnly: Data) throws -> P256K.KeyAgreement.PublicKey {
        var even = Data([0x02])
        even.append(xOnly)
        if let key = try? P256K.KeyAgreement.PublicKey(dataRepresentation: even, format: .compressed) {
            return key
        }
        var odd = Data([0x03])
        odd.append(xOnly)
        return try P256K.KeyAgreement.PublicKey(dataRepresentation: odd, format: .compressed)
    }
}
