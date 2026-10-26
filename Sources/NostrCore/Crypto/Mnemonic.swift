import Crypto
import Foundation

/// Represents a BIP-39 mnemonic seed phrase for NIP-06 key derivation
public struct Mnemonic: Sendable {
    /// The mnemonic words
    public let words: [String]

    /// The mnemonic phrase as a space-separated string
    public var phrase: String {
        words.joined(separator: " ")
    }

    /// Number of words in the mnemonic
    public var wordCount: Int {
        words.count
    }

    // MARK: - Initialization

    /// Creates a mnemonic from a space-separated phrase
    /// - Throws: The errors of ``init(words:)``.
    public init(phrase: String) throws(Mnemonic.Error) {
        let words = phrase.split(separator: " ").map(String.init)
        try self.init(words: words)
    }

    /// Creates a mnemonic from an array of words
    /// - Throws: ``Mnemonic/Error/invalidWordCount(_:)`` unless there are 12, 15, 18, 21, or 24
    ///   words, ``Mnemonic/Error/unknownWord(_:)`` for the first word not in the BIP-39 English
    ///   word list, or ``Mnemonic/Error/invalidChecksum`` if the checksum does not match.
    public init(words: [String]) throws(Mnemonic.Error) {
        guard [12, 15, 18, 21, 24].contains(words.count) else {
            throw .invalidWordCount(words.count)
        }

        // Validate all words are in the wordlist
        for word in words {
            guard BIP39WordList.english.contains(word) else {
                throw .unknownWord(word)
            }
        }

        // Validate checksum
        guard Self.validateChecksum(words: words) else {
            throw .invalidChecksum
        }

        self.words = words
    }

    /// Generates a new random mnemonic with the specified word count
    /// - Throws: ``Mnemonic/Error/invalidWordCount(_:)`` unless `wordCount` is 12, 15, 18, 21, or 24.
    public static func generate(wordCount: Int = 12) throws(Mnemonic.Error) -> Mnemonic {
        guard [12, 15, 18, 21, 24].contains(wordCount) else {
            throw .invalidWordCount(wordCount)
        }

        // Calculate entropy bytes needed
        // 12 words = 128 bits = 16 bytes
        // 15 words = 160 bits = 20 bytes
        // 18 words = 192 bits = 24 bytes
        // 21 words = 224 bits = 28 bytes
        // 24 words = 256 bits = 32 bytes
        let entropyBytes = wordCount * 4 / 3

        let entropy = SecureRandom.generateBytes(count: entropyBytes)

        return try Mnemonic(entropy: entropy)
    }

    /// Creates a mnemonic from BIP-39 entropy: 16, 20, 24, 28 or 32 bytes for 12 to 24 words.
    /// - Throws: ``Mnemonic/Error/invalidEntropyLength(_:)`` for any other byte count.
    public init(entropy: Data) throws(Mnemonic.Error) {
        guard [16, 20, 24, 28, 32].contains(entropy.count) else {
            throw .invalidEntropyLength(entropy.count)
        }

        // Calculate checksum
        let hash = Data(SHA256.hash(data: entropy))
        let checksumBits = entropy.count / 4

        // Convert entropy + checksum to bits
        var bits = entropy.flatMap { byte in
            (0..<8).map { bit in
                (byte >> (7 - bit)) & 1
            }
        }

        // Add checksum bits
        for i in 0..<checksumBits {
            let bit = (hash[i / 8] >> (7 - (i % 8))) & 1
            bits.append(bit)
        }

        // Convert bits to word indices (11 bits per word)
        let wordCount = bits.count / 11
        var words: [String] = []

        for i in 0..<wordCount {
            var index = 0
            for j in 0..<11 {
                index = (index << 1) | Int(bits[i * 11 + j])
            }
            words.append(BIP39WordList.english[index])
        }

        try self.init(words: words)
    }

    // MARK: - Seed Derivation

    /// Derives the BIP-39 seed from the mnemonic using PBKDF2
    /// - Parameter passphrase: Optional passphrase for additional security
    /// - Returns: 64-byte seed
    public func seed(passphrase: String = "") -> Data {
        let password = phrase.decomposedStringWithCompatibilityMapping
        let salt = ("mnemonic" + passphrase).decomposedStringWithCompatibilityMapping

        return pbkdf2SHA512(
            password: Data(password.utf8),
            salt: Data(salt.utf8),
            iterations: 2048,
            keyLength: 64
        )
    }

    // MARK: - Private Methods

    /// Validates the checksum of a mnemonic
    private static func validateChecksum(words: [String]) -> Bool {
        // Convert words to indices
        var indices: [Int] = []
        for word in words {
            guard let index = BIP39WordList.english.firstIndex(of: word) else {
                return false
            }
            indices.append(index)
        }

        // Convert indices to bits
        var bits: [UInt8] = []
        for index in indices {
            for i in (0..<11).reversed() {
                bits.append(UInt8((index >> i) & 1))
            }
        }

        // Split into entropy and checksum
        let checksumLength = words.count / 3
        let entropyBits = bits.count - checksumLength

        // Convert entropy bits to bytes
        var entropy = Data()
        for i in stride(from: 0, to: entropyBits, by: 8) {
            var byte: UInt8 = 0
            for j in 0..<8 {
                byte = (byte << 1) | bits[i + j]
            }
            entropy.append(byte)
        }

        // Calculate expected checksum
        let hash = Data(SHA256.hash(data: entropy))

        // Extract checksum bits from hash
        var expectedChecksum: [UInt8] = []
        for i in 0..<checksumLength {
            let bit = (hash[i / 8] >> (7 - (i % 8))) & 1
            expectedChecksum.append(bit)
        }

        // Compare with actual checksum
        let actualChecksum = Array(bits[entropyBits...])
        return expectedChecksum == actualChecksum
    }

    /// PBKDF2 with SHA-512 - Pure Swift implementation for cross-platform support
    private func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hashLength = 64  // SHA-512 output size
        let numBlocks = (keyLength + hashLength - 1) / hashLength

        var derivedKey = Data()

        for blockIndex in 1...numBlocks {
            // First iteration: U_1 = PRF(Password, Salt || INT(i))
            var saltWithIndex = salt
            saltWithIndex.append(contentsOf: withUnsafeBytes(of: UInt32(blockIndex).bigEndian) { Array($0) })

            var u = Data(
                HMAC<SHA512>.authenticationCode(
                    for: saltWithIndex,
                    using: SymmetricKey(data: password)
                ))
            var result = u

            // Subsequent iterations: U_n = PRF(Password, U_{n-1})
            for _ in 1..<iterations {
                u = Data(
                    HMAC<SHA512>.authenticationCode(
                        for: u,
                        using: SymmetricKey(data: password)
                    ))
                // XOR with previous result
                for i in 0..<hashLength {
                    result[i] ^= u[i]
                }
            }

            derivedKey.append(result)
        }

        return Data(derivedKey.prefix(keyLength))
    }
}

extension Mnemonic {
    /// Why a mnemonic could not be created.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The word count is not 12, 15, 18, 21, or 24 (payload: the count given).
        case invalidWordCount(Int)
        /// A word is not in the BIP-39 English word list (payload: the word).
        case unknownWord(String)
        /// The words are all valid but their checksum does not match.
        case invalidChecksum
        /// The entropy is not 16, 20, 24, 28, or 32 bytes (payload: its byte count).
        case invalidEntropyLength(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidWordCount(let count):
                return "A mnemonic must have 12, 15, 18, 21, or 24 words, got \(count)"
            case .unknownWord(let word):
                return "Invalid mnemonic word: \(word)"
            case .invalidChecksum:
                return "Invalid mnemonic checksum"
            case .invalidEntropyLength(let count):
                return "Mnemonic entropy must be 16, 20, 24, 28, or 32 bytes, got \(count)"
            }
        }
    }
}
