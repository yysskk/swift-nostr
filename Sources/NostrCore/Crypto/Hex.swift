import Foundation

// MARK: - Hexadecimal Encoding

extension Data {
    /// Creates data by decoding a hexadecimal string.
    ///
    /// The string must contain an even number of ASCII hexadecimal digits (`0`–`9`, `a`–`f`,
    /// `A`–`F`); decoding is case-insensitive. Returns `nil` if the string has an odd length or
    /// contains anything else — including a leading `+` or `-`, which the standard integer parser
    /// would otherwise accept.
    package init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            // `UInt8(_:radix:)` accepts a leading `+` or `-`, so it decodes "+1" as 1. Left to it,
            // one byte string would have several spellings that all decode to the same identity.
            // Each character is checked explicitly first so only plain hex digits get through.
            guard hex[index..<nextIndex].allSatisfy(\.isHexDigitASCII),
                let byte = UInt8(hex[index..<nextIndex], radix: 16)
            else {
                return nil
            }
            data.append(byte)
            index = nextIndex
        }

        self = data
    }

    /// Returns the data as a lowercase hexadecimal string.
    package func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension Character {
    /// Whether this is one of the ASCII hexadecimal digits.
    ///
    /// Narrower than `isHexDigit`, which also accepts the fullwidth forms of the same digits.
    fileprivate var isHexDigitASCII: Bool {
        isASCII && isHexDigit
    }
}

extension String {
    /// Whether this is the canonical hex spelling of exactly `byteCount` bytes: `2 * byteCount`
    /// lowercase ASCII hexadecimal digits (`0`–`9`, `a`–`f`) and nothing else.
    ///
    /// The canonical form is what ``PublicKey``, ``EventID``, and ``Signature`` accept, so a value
    /// has exactly one textual spelling and anything keyed on that string stays in step with the
    /// bytes it names.
    func isCanonicalHex(byteCount: Int) -> Bool {
        utf8.count == byteCount * 2
            && utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}

extension Data {
    /// Decodes a string already known to be canonical hex (see `String.isCanonicalHex(byteCount:)`).
    ///
    /// Non-failing because the typed hex values validate their spelling once, when they are made;
    /// reading their bytes back afterwards cannot meet a malformed digit.
    init(canonicalHex hex: String) {
        func nibble(_ digit: UInt8) -> UInt8 {
            digit <= 0x39 ? digit - 0x30 : digit - 0x61 + 10
        }
        let digits = Array(hex.utf8)
        var data = Data(capacity: digits.count / 2)
        var index = 0
        while index + 1 < digits.count {
            data.append(nibble(digits[index]) << 4 | nibble(digits[index + 1]))
            index += 2
        }
        self = data
    }
}
