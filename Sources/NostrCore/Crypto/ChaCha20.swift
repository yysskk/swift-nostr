import Foundation

/// The ChaCha20 stream cipher (RFC 8439 §2.4) with a 256-bit key, 96-bit nonce, and a 32-bit
/// block counter starting at 0 — the form NIP-44 v2 uses (not the AEAD, whose message keystream
/// starts at counter 1 because counter 0 is reserved for the Poly1305 one-time key).
///
/// https://datatracker.ietf.org/doc/html/rfc8439#section-2.4
enum ChaCha20 {
    /// The ChaCha "expand 32-byte k" constants (RFC 8439 §2.3), state words 0..3.
    private static let constants: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    /// XORs `data` with the ChaCha20 keystream and returns the result. Because ChaCha20 is a
    /// stream cipher, the same call both encrypts and decrypts.
    /// - Parameters:
    ///   - data: The bytes to combine with the keystream.
    ///   - key: The 32-byte key.
    ///   - nonce: The 12-byte nonce.
    ///   - initialCounter: The block counter for the first keystream block (0 for NIP-44).
    /// - Returns: `data` XORed with the keystream, the same length as `data`.
    static func xor(_ data: Data, key: Data, nonce: Data, initialCounter: UInt32 = 0) throws -> Data {
        guard key.count == 32 else { throw NostrError.invalidData }
        guard nonce.count == 12 else { throw NostrError.invalidData }

        var result = Data(capacity: data.count)
        var counter = initialCounter
        var offset = data.startIndex

        while offset < data.endIndex {
            let block = keystreamBlock(key: key, nonce: nonce, counter: counter)

            let remaining = data.distance(from: offset, to: data.endIndex)
            let blockLength = min(64, remaining)
            for index in 0..<blockLength {
                result.append(data[data.index(offset, offsetBy: index)] ^ block[index])
            }

            offset = data.index(offset, offsetBy: blockLength)
            counter &+= 1
        }

        return result
    }

    /// Runs the ChaCha20 block function (RFC 8439 §2.3) and returns the 64-byte keystream block
    /// for the given counter.
    private static func keystreamBlock(key: Data, nonce: Data, counter: UInt32) -> [UInt8] {
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

        // Word 12: block counter.
        state[12] = counter

        // Words 13..15: nonce, as three little-endian 32-bit words.
        for index in 0..<3 {
            state[13 + index] = loadLittleEndian(nonce, offset: index * 4)
        }

        var working = state

        // Twenty rounds: ten iterations of four column rounds followed by four diagonal rounds.
        for _ in 0..<10 {
            // Column rounds.
            quarterRound(&working, 0, 4, 8, 12)
            quarterRound(&working, 1, 5, 9, 13)
            quarterRound(&working, 2, 6, 10, 14)
            quarterRound(&working, 3, 7, 11, 15)
            // Diagonal rounds.
            quarterRound(&working, 0, 5, 10, 15)
            quarterRound(&working, 1, 6, 11, 12)
            quarterRound(&working, 2, 7, 8, 13)
            quarterRound(&working, 3, 4, 9, 14)
        }

        // A full ChaCha20 block adds the original state back before serialization.
        var block = [UInt8]()
        block.reserveCapacity(64)
        for index in 0..<16 {
            appendLittleEndian(working[index] &+ state[index], to: &block)
        }
        return block
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

    /// Appends a 32-bit word to `bytes` in little-endian byte order.
    private static func appendLittleEndian(_ value: UInt32, to bytes: inout [UInt8]) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }
}
