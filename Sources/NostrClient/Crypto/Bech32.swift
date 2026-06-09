import Foundation

/// Bech32 encoding/decoding for Nostr keys (NIP-19)
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static let charsetMap: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in charset.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()

    /// Encodes data with the given human-readable prefix
    public static func encode(hrp: String, data: Data) -> String {
        let values = convertBits(from: 8, to: 5, data: Array(data), pad: true)
        let checksum = createChecksum(hrp: hrp, values: values)
        let combined = values + checksum
        return hrp + "1" + String(combined.map { charset[Int($0)] })
    }

    /// Decodes a bech32 string, returning the prefix and data
    public static func decode(_ str: String) throws -> (hrp: String, data: Data) {
        let lowercased = str.lowercased()

        guard let separatorIndex = lowercased.lastIndex(of: "1") else {
            throw NostrError.invalidBech32
        }

        let hrp = String(lowercased[..<separatorIndex])
        let dataPartStart = lowercased.index(after: separatorIndex)
        let dataPart = String(lowercased[dataPartStart...])

        guard hrp.count >= 1, dataPart.count >= 6 else {
            throw NostrError.invalidBech32
        }

        var values = [UInt8]()
        for char in dataPart {
            guard let value = charsetMap[char] else {
                throw NostrError.invalidBech32
            }
            values.append(value)
        }

        guard verifyChecksum(hrp: hrp, values: values) else {
            throw NostrError.invalidBech32
        }

        // Remove checksum (last 6 characters)
        let dataValues = Array(values.dropLast(6))
        let decoded = convertBits(from: 5, to: 8, data: dataValues, pad: false)

        return (hrp, Data(decoded))
    }

    // MARK: - Private Helpers

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var chk: UInt32 = 1

        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ffffff) << 5 ^ UInt32(value)
            for i in 0..<5 {
                if (top >> i) & 1 == 1 {
                    chk ^= generator[i]
                }
            }
        }

        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp {
            result.append(UInt8(char.asciiValue! >> 5))
        }
        result.append(0)
        for char in hrp {
            result.append(UInt8(char.asciiValue! & 31))
        }
        return result
    }

    private static func verifyChecksum(hrp: String, values: [UInt8]) -> Bool {
        polymod(hrpExpand(hrp) + values) == 1
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let polymodInput = hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]
        let mod = polymod(polymodInput) ^ 1
        var result = [UInt8]()
        for i in 0..<6 {
            result.append(UInt8((mod >> (5 * (5 - i))) & 31))
        }
        return result
    }

    private static func convertBits(from: Int, to: Int, data: [UInt8], pad: Bool) -> [UInt8] {
        var acc = 0
        var bits = 0
        var result = [UInt8]()
        let maxv = (1 << to) - 1

        for value in data {
            acc = (acc << from) | Int(value)
            bits += from
            while bits >= to {
                bits -= to
                result.append(UInt8((acc >> bits) & maxv))
            }
        }

        if pad {
            if bits > 0 {
                result.append(UInt8((acc << (to - bits)) & maxv))
            }
        }

        return result
    }
}
