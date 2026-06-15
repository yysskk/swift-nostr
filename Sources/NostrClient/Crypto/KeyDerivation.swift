import Crypto
import Foundation
import NostrCore
import P256K

/// Key derivation for NIP-06 using BIP-32/BIP-39
public enum KeyDerivation {
    /// The hardened offset for BIP-32 derivation (2^31)
    public static let hardenedOffset: UInt32 = 0x8000_0000

    /// BIP-44 purpose
    public static let bip44Purpose: UInt32 = 44

    /// SLIP-44 coin type for Nostr
    public static let nostrCoinType: UInt32 = 1237

    /// Derives a Nostr private key from a BIP-39 seed using the NIP-06 derivation path
    /// Path: m/44'/1237'/<account>'/0/0
    /// - Parameters:
    ///   - seed: The 64-byte BIP-39 seed
    ///   - account: The account index (default 0)
    /// - Returns: 32-byte private key
    public static func deriveNostrKey(seed: Data, account: UInt32 = 0) throws -> Data {
        // Generate master key from seed
        let (masterKey, masterChainCode) = try masterKeyFromSeed(seed)

        // Derive path: m/44'/1237'/<account>'/0/0
        var key = masterKey
        var chainCode = masterChainCode

        // 44' (hardened)
        (key, chainCode) = try deriveChildKey(
            parentKey: key,
            parentChainCode: chainCode,
            index: bip44Purpose | hardenedOffset
        )

        // 1237' (hardened)
        (key, chainCode) = try deriveChildKey(
            parentKey: key,
            parentChainCode: chainCode,
            index: nostrCoinType | hardenedOffset
        )

        // account' (hardened)
        (key, chainCode) = try deriveChildKey(
            parentKey: key,
            parentChainCode: chainCode,
            index: account | hardenedOffset
        )

        // 0 (normal)
        (key, chainCode) = try deriveChildKey(
            parentKey: key,
            parentChainCode: chainCode,
            index: 0
        )

        // 0 (normal)
        (key, _) = try deriveChildKey(
            parentKey: key,
            parentChainCode: chainCode,
            index: 0
        )

        return key
    }

    /// Generates the master key and chain code from a seed using HMAC-SHA512
    private static func masterKeyFromSeed(_ seed: Data) throws -> (key: Data, chainCode: Data) {
        let hmacKey = Data("Bitcoin seed".utf8)
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: SymmetricKey(data: hmacKey))
        let hmacData = Data(hmac)

        let key = hmacData.prefix(32)
        let chainCode = hmacData.suffix(32)

        // Validate key is valid for secp256k1
        guard isValidPrivateKey(key) else {
            throw NostrError.invalidPrivateKey
        }

        return (Data(key), Data(chainCode))
    }

    /// Derives a child key using BIP-32
    private static func deriveChildKey(
        parentKey: Data,
        parentChainCode: Data,
        index: UInt32
    ) throws -> (key: Data, chainCode: Data) {
        var data = Data()

        if index >= hardenedOffset {
            // Hardened child: 0x00 || parent_key || index
            data.append(0x00)
            data.append(parentKey)
        } else {
            // Normal child: parent_public_key || index
            let publicKey = try compressedPublicKey(from: parentKey)
            data.append(publicKey)
        }

        // Append index as big-endian
        data.append(contentsOf: withUnsafeBytes(of: index.bigEndian) { Array($0) })

        // HMAC-SHA512
        let hmac = HMAC<SHA512>.authenticationCode(
            for: data,
            using: SymmetricKey(data: parentChainCode)
        )
        let hmacData = Data(hmac)

        let il = hmacData.prefix(32)
        let chainCode = Data(hmacData.suffix(32))

        // Calculate child key: (il + parent_key) mod n
        let childKey = try addPrivateKeys(il, parentKey)

        guard isValidPrivateKey(childKey) else {
            throw NostrError.invalidPrivateKey
        }

        return (childKey, chainCode)
    }

    /// Checks if a private key is valid for secp256k1
    private static func isValidPrivateKey(_ key: Data) -> Bool {
        guard key.count == 32 else { return false }

        // Key must be non-zero
        if key.allSatisfy({ $0 == 0 }) { return false }

        // Key must be less than the curve order n
        let n = secp256k1Order
        return compareBytes(key, n) < 0
    }

    /// secp256k1 curve order
    private static let secp256k1Order: Data = {
        var order = Data(count: 32)
        let orderHex = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"
        for (i, j) in stride(from: 0, to: orderHex.count, by: 2).enumerated() {
            let startIndex = orderHex.index(orderHex.startIndex, offsetBy: j)
            let endIndex = orderHex.index(startIndex, offsetBy: 2)
            order[i] = UInt8(orderHex[startIndex..<endIndex], radix: 16)!
        }
        return order
    }()

    /// Compares two byte arrays as big integers
    private static func compareBytes(_ a: Data, _ b: Data) -> Int {
        for i in 0..<min(a.count, b.count) {
            if a[i] < b[i] { return -1 }
            if a[i] > b[i] { return 1 }
        }
        return a.count - b.count
    }

    /// Adds two private keys modulo the curve order
    private static func addPrivateKeys(_ a: Data, _ b: Data) throws -> Data {
        let n = secp256k1Order

        // Convert to big integers and add
        var result = Data(count: 33)
        var carry: UInt16 = 0

        for i in (0..<32).reversed() {
            let sum = UInt16(a[i]) + UInt16(b[i]) + carry
            result[i + 1] = UInt8(sum & 0xFF)
            carry = sum >> 8
        }
        result[0] = UInt8(carry)

        // Reduce modulo n
        while compareBytes(Data(result.suffix(32)), n) >= 0 || result[0] != 0 {
            var borrow: Int16 = 0
            for i in (0..<32).reversed() {
                let diff = Int16(result[i + 1]) - Int16(n[i]) - borrow
                if diff < 0 {
                    result[i + 1] = UInt8((diff + 256) & 0xFF)
                    borrow = 1
                } else {
                    result[i + 1] = UInt8(diff)
                    borrow = 0
                }
            }
            result[0] = UInt8(max(0, Int16(result[0]) - borrow))
        }

        return Data(result.suffix(32))
    }

    /// Computes the compressed public key from a private key
    /// Returns 33-byte compressed public key with 02/03 prefix
    private static func compressedPublicKey(from privateKey: Data) throws -> Data {
        let signingKey = try P256K.Signing.PrivateKey(dataRepresentation: privateKey)
        return Data(signingKey.publicKey.dataRepresentation)
    }
}
