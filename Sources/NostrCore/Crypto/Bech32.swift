import Foundation

/// Bech32 encoding/decoding for Nostr keys (NIP-19)
/// https://github.com/nostr-protocol/nips/blob/master/19.md
package enum Bech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    private static let charsetMap: [Character: UInt8] = {
        var map = [Character: UInt8]()
        for (i, c) in charset.enumerated() {
            map[c] = UInt8(i)
        }
        return map
    }()

    /// Encodes data with the given human-readable prefix.
    ///
    /// The prefix must be non-empty and consist of lowercase printable ASCII (`!` through `~`).
    /// Uppercase is rejected rather than folded: the checksum covers the prefix as written, while
    /// decoding recomputes it over the lowercased string, so an uppercase prefix would produce a
    /// string that ``decode(_:)`` could never accept.
    /// - Throws: ``Bech32Error/invalidHumanReadablePart`` if `hrp` is empty or not lowercase
    ///   printable ASCII.
    package static func encode(hrp: String, data: Data) throws(Bech32Error) -> String {
        guard !hrp.isEmpty,
            hrp.allSatisfy({ $0.isASCII && !$0.isUppercase && ("!"..."~").contains($0) })
        else {
            throw .invalidHumanReadablePart
        }
        return encode(validatedHRP: hrp, data: data)
    }

    /// Encodes data under a prefix the caller has already checked, or that is a known-valid
    /// constant such as `"npub"` or `"note"` — which is what lets ``PublicKey/npub`` and
    /// ``EventID/note`` be non-throwing.
    static func encode(validatedHRP hrp: String, data: Data) -> String {
        let values = convertBits(from: 8, to: 5, data: Array(data), pad: true)
        let checksum = createChecksum(hrp: hrp, values: values)
        let combined = values + checksum
        return hrp + "1" + String(combined.map { charset[Int($0)] })
    }

    /// Decodes a bech32 string, returning the prefix and data.
    ///
    /// The payload must be byte-aligned and canonically padded, as BIP-173 requires of a decoder:
    /// the bits left over after regrouping must number fewer than five and must all be zero.
    /// Otherwise a single payload would have many checksum-valid spellings — for a 32-byte key,
    /// sixteen — and each would decode to the same bytes, so anything keyed on the string form
    /// could be desynchronized from the identity it names.
    ///
    /// The string must also be all-lowercase or all-uppercase; see ``decodeToWords(_:)``.
    /// - Throws: The errors of ``decodeToWords(_:)``, or ``Bech32Error/invalidPadding`` if the
    ///   payload is not canonically padded.
    package static func decode(_ str: String) throws(Bech32Error) -> (hrp: String, data: Data) {
        let (hrp, words) = try decodeToWords(str)
        return (hrp, Data(try wordsToBytesCanonical(words)))
    }

    /// Decodes a bech32 string to its 5-bit data words, with the checksum verified and removed but
    /// without regrouping into bytes.
    ///
    /// Useful for formats whose data is not byte-aligned and so cannot survive the 5→8 bit
    /// conversion, such as BOLT-11 Lightning invoices. Because the words are returned unregrouped,
    /// no padding rule applies here — only ``decode(_:)`` enforces canonical padding.
    ///
    /// Decoding is case-insensitive, but BIP-173 forbids mixing: the string must be entirely
    /// lowercase or entirely uppercase. Uppercase is common in QR codes, so both remain valid.
    /// - Throws: ``Bech32Error/mixedCase`` if the string mixes case,
    ///   ``Bech32Error/missingSeparator`` if it has no `1`, ``Bech32Error/invalidLength`` if the
    ///   prefix is empty or the data part shorter than the checksum,
    ///   ``Bech32Error/invalidHumanReadablePart`` if the prefix is not ASCII,
    ///   ``Bech32Error/invalidCharacter(_:)`` for a character outside the bech32 alphabet, or
    ///   ``Bech32Error/invalidChecksum`` if the checksum does not match.
    package static func decodeToWords(_ str: String) throws(Bech32Error) -> (hrp: String, words: [UInt8]) {
        // BIP-173: "Decoders MUST NOT accept strings where some characters are uppercase and some
        // are lowercase." Checked before folding the case, which would otherwise hide the mix.
        guard !(str.contains(where: \.isUppercase) && str.contains(where: \.isLowercase)) else {
            throw .mixedCase
        }

        let lowercased = str.lowercased()

        guard let separatorIndex = lowercased.lastIndex(of: "1") else {
            throw .missingSeparator
        }

        let hrp = String(lowercased[..<separatorIndex])
        let dataPartStart = lowercased.index(after: separatorIndex)
        let dataPart = String(lowercased[dataPartStart...])

        guard hrp.count >= 1, dataPart.count >= 6 else {
            throw .invalidLength
        }

        // The HRP must be ASCII: `hrpExpand` (used by the checksum) reads each
        // character's `asciiValue`, so a non-ASCII HRP would otherwise trap.
        guard hrp.allSatisfy(\.isASCII) else {
            throw .invalidHumanReadablePart
        }

        var values = [UInt8]()
        for char in dataPart {
            guard let value = charsetMap[char] else {
                throw .invalidCharacter(char)
            }
            values.append(value)
        }

        guard verifyChecksum(hrp: hrp, values: values) else {
            throw .invalidChecksum
        }

        // Remove the checksum (the last 6 words).
        return (hrp, Array(values.dropLast(6)))
    }

    /// Regroups 5-bit bech32 words into 8-bit bytes, dropping any partial trailing bits.
    ///
    /// Deliberately lenient, for callers that slice a payload into fields that are not individually
    /// byte-aligned — a BOLT-11 invoice's 52-word payment hash carries four trailing bits that the
    /// format expects to be discarded. Use ``decode(_:)`` for whole payloads that must be
    /// canonically padded.
    package static func wordsToBytes(_ words: [UInt8]) -> [UInt8] {
        convertBits(from: 5, to: 8, data: words, pad: false)
    }

    // MARK: - Private Helpers

    /// Regroups 5-bit words into bytes, rejecting a payload that is not canonically padded.
    ///
    /// BIP-173 requires both checks: five or more leftover bits mean the payload could have been
    /// written in fewer words, and non-zero leftover bits mean the padding carries information the
    /// byte payload does not, which is what gives one key several valid spellings.
    private static func wordsToBytesCanonical(_ words: [UInt8]) throws(Bech32Error) -> [UInt8] {
        var acc = 0
        var bits = 0
        var result = [UInt8]()

        for value in words {
            acc = (acc << 5) | Int(value)
            bits += 5
            while bits >= 8 {
                bits -= 8
                result.append(UInt8((acc >> bits) & 0xff))
            }
        }

        guard bits < 5, acc & ((1 << bits) - 1) == 0 else {
            throw .invalidPadding
        }

        return result
    }

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

/// Why a string could not be bech32-encoded or decoded.
///
/// These describe the encoding only, and reach callers as the associated value of the
/// `invalidBech32` case of a typed error — ``PublicKey/Error/invalidBech32(_:)``, for example.
/// Whether a well-formed string carries the expected prefix is for the caller to check — see
/// ``PublicKey/init(npub:)``.
public enum Bech32Error: Error, LocalizedError, Sendable, Equatable {
    /// The human-readable prefix is not allowed: when encoding, it is empty or not lowercase
    /// printable ASCII; when decoding, it contains a non-ASCII character.
    case invalidHumanReadablePart
    /// The string mixes uppercase and lowercase characters, which BIP-173 forbids.
    case mixedCase
    /// The string has no `1` separating the prefix from the data part.
    case missingSeparator
    /// The prefix is empty, or the data part is shorter than the six-character checksum.
    case invalidLength
    /// The data part contains a character outside the bech32 alphabet.
    case invalidCharacter(Character)
    /// The checksum does not match the prefix and data.
    case invalidChecksum
    /// The data does not regroup into whole bytes with canonical, all-zero padding.
    case invalidPadding

    public var errorDescription: String? {
        switch self {
        case .invalidHumanReadablePart:
            return "Invalid bech32 human-readable prefix"
        case .mixedCase:
            return "The bech32 string mixes uppercase and lowercase characters"
        case .missingSeparator:
            return "The bech32 string has no separator"
        case .invalidLength:
            return "The bech32 string has an empty prefix or a data part shorter than its checksum"
        case .invalidCharacter(let character):
            return "Invalid bech32 character: \(character)"
        case .invalidChecksum:
            return "Invalid bech32 checksum"
        case .invalidPadding:
            return "The bech32 data is not canonically padded"
        }
    }
}
