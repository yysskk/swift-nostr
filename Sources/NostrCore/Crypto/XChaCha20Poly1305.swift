import Crypto
import Foundation

/// HChaCha20 (draft-irtf-cfrg-xchacha-03 §2.2): derives a 32-byte subkey from a 32-byte key
/// and a 16-byte nonce using the ChaCha20 block function without the final state addition.
///
/// https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-xchacha-03#section-2.2
enum HChaCha20 {
    /// The ChaCha "expand 32-byte k" constants (RFC 8439 §2.3), state words 0..3.
    private static let constants: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    /// Runs the HChaCha20 block function.
    /// - Returns: the 32-byte subkey (state words 0..3 concatenated with words 12..15).
    /// - Precondition: `key` is 32 bytes and `nonce` 16.
    static func deriveSubkey(key: Data, nonce: Data) -> Data {
        precondition(key.count == 32, "An HChaCha20 key is 32 bytes")
        precondition(nonce.count == 16, "An HChaCha20 nonce is 16 bytes")

        var state = [UInt32](repeating: 0, count: 16)

        // Words 0..3: constants.
        state[0] = constants[0]
        state[1] = constants[1]
        state[2] = constants[2]
        state[3] = constants[3]

        // Words 4..11: key, as eight little-endian 32-bit words.
        for index in 0..<8 {
            state[4 + index] = loadLittleEndian(key, offset: index * 4)
        }

        // Words 12..15: nonce, as four little-endian 32-bit words.
        for index in 0..<4 {
            state[12 + index] = loadLittleEndian(nonce, offset: index * 4)
        }

        // Twenty rounds: ten iterations of four column rounds followed by four diagonal rounds.
        // Unlike ChaCha20, HChaCha20 does not add the original state back at the end.
        for _ in 0..<10 {
            // Column rounds.
            quarterRound(&state, 0, 4, 8, 12)
            quarterRound(&state, 1, 5, 9, 13)
            quarterRound(&state, 2, 6, 10, 14)
            quarterRound(&state, 3, 7, 11, 15)
            // Diagonal rounds.
            quarterRound(&state, 0, 5, 10, 15)
            quarterRound(&state, 1, 6, 11, 12)
            quarterRound(&state, 2, 7, 8, 13)
            quarterRound(&state, 3, 4, 9, 14)
        }

        // Output: words 0,1,2,3,12,13,14,15 serialized little-endian.
        var subkey = Data(capacity: 32)
        for index in [0, 1, 2, 3, 12, 13, 14, 15] {
            appendLittleEndian(state[index], to: &subkey)
        }
        return subkey
    }

    /// The ChaCha quarter round (RFC 8439 §2.1) operating on four words of the state.
    private static func quarterRound(_ state: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        state[a] = state[a] &+ state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 16)
        state[c] = state[c] &+ state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 12)
        state[a] = state[a] &+ state[b]
        state[d] = rotateLeft(state[d] ^ state[a], by: 8)
        state[c] = state[c] &+ state[d]
        state[b] = rotateLeft(state[b] ^ state[c], by: 7)
    }

    /// Rotates a 32-bit word left by `amount` bits.
    private static func rotateLeft(_ value: UInt32, by amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }

    /// Reads a little-endian 32-bit word from `data` at the given byte offset.
    private static func loadLittleEndian(_ data: Data, offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    /// Appends a 32-bit word to `data` in little-endian byte order.
    private static func appendLittleEndian(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }
}

/// XChaCha20-Poly1305 AEAD (draft-irtf-cfrg-xchacha-03 §2.3): 24-byte nonce, composed from
/// HChaCha20 + IETF ChaCha20-Poly1305.
///
/// This primitive is not offered by swift-crypto, which only exposes the IETF `ChaChaPoly`
/// construction with a 12-byte nonce. The extended nonce is handled by deriving a subkey with
/// HChaCha20 and then reducing to the IETF construction.
///
/// https://datatracker.ietf.org/doc/html/draft-irtf-cfrg-xchacha-03#section-2.3
enum XChaCha20Poly1305 {
    /// The ciphertext did not authenticate under the key, nonce, and associated data. Each public
    /// caller maps this into its own domain error.
    struct AuthenticationFailure: Error {}

    /// The Poly1305 authentication tag length, in bytes.
    private static let tagLength = 16

    /// Seals `plaintext`. Returns ciphertext with the 16-byte Poly1305 tag appended.
    /// - Precondition: `key` is 32 bytes and `nonce` 24.
    static func seal(
        _ plaintext: Data,
        key: Data,
        nonce: Data,
        authenticating aad: Data = Data()
    ) -> Data {
        precondition(key.count == 32, "An XChaCha20-Poly1305 key is 32 bytes")
        precondition(nonce.count == 24, "An XChaCha20-Poly1305 nonce is 24 bytes")

        let (subkey, ietfNonce) = deriveSubkeyAndNonce(key: key, nonce: nonce)

        // swift-crypto only rejects a wrong-length key or nonce, which the preconditions rule out.
        let sealedBox: ChaChaPoly.SealedBox
        do {
            sealedBox = try ChaChaPoly.seal(
                plaintext,
                using: SymmetricKey(data: subkey),
                nonce: ChaChaPoly.Nonce(data: ietfNonce),
                authenticating: aad
            )
        } catch {
            preconditionFailure("ChaChaPoly rejected a 32-byte key and a 12-byte nonce: \(error)")
        }

        // `sealedBox.combined` prefixes the nonce, so assemble ciphertext‖tag explicitly.
        // `ciphertext` is a slice of the combined buffer, so wrap the result in a fresh
        // `Data` to guarantee a zero-based index range for callers.
        var result = Data(capacity: sealedBox.ciphertext.count + sealedBox.tag.count)
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)
        return result
    }

    /// Opens `ciphertext` (tag appended), authenticating `aad`.
    /// - Throws: ``AuthenticationFailure`` if `ciphertext` is shorter than the tag or does not
    ///   authenticate.
    /// - Precondition: `key` is 32 bytes and `nonce` 24.
    static func open(
        _ ciphertext: Data,
        key: Data,
        nonce: Data,
        authenticating aad: Data = Data()
    ) throws(AuthenticationFailure) -> Data {
        precondition(key.count == 32, "An XChaCha20-Poly1305 key is 32 bytes")
        precondition(nonce.count == 24, "An XChaCha20-Poly1305 nonce is 24 bytes")
        guard ciphertext.count >= tagLength else { throw AuthenticationFailure() }

        let (subkey, ietfNonce) = deriveSubkeyAndNonce(key: key, nonce: nonce)

        // Data slices keep their parent's indices, so re-wrap in fresh Data values.
        let splitIndex = ciphertext.index(ciphertext.endIndex, offsetBy: -tagLength)
        let cipher = Data(ciphertext[ciphertext.startIndex..<splitIndex])
        let tag = Data(ciphertext[splitIndex...])

        do {
            let sealedBox = try ChaChaPoly.SealedBox(
                nonce: ChaChaPoly.Nonce(data: ietfNonce),
                ciphertext: cipher,
                tag: tag
            )
            return try ChaChaPoly.open(sealedBox, using: SymmetricKey(data: subkey), authenticating: aad)
        } catch {
            throw AuthenticationFailure()
        }
    }

    /// Derives the HChaCha20 subkey and the 12-byte IETF nonce (four zero bytes followed by the
    /// last eight bytes of the 24-byte nonce) shared by ``seal(_:key:nonce:authenticating:)`` and
    /// ``open(_:key:nonce:authenticating:)``.
    private static func deriveSubkeyAndNonce(key: Data, nonce: Data) -> (subkey: Data, ietfNonce: Data) {
        let hchachaNonce = Data(nonce[nonce.startIndex..<nonce.index(nonce.startIndex, offsetBy: 16)])
        let subkey = HChaCha20.deriveSubkey(key: key, nonce: hchachaNonce)

        var ietfNonce = Data(repeating: 0, count: 4)
        ietfNonce.append(Data(nonce[nonce.index(nonce.startIndex, offsetBy: 16)...]))

        return (subkey, ietfNonce)
    }
}
