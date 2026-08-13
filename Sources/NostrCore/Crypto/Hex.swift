import Foundation

// MARK: - Hexadecimal Encoding

extension Data {
    /// Creates data by decoding a hexadecimal string.
    ///
    /// The string must contain an even number of ASCII hexadecimal digits (`0`–`9`, `a`–`f`,
    /// `A`–`F`); decoding is case-insensitive. Returns `nil` if the string has an odd length or
    /// contains anything else — including a leading `+` or `-`, which the standard integer parser
    /// would otherwise accept.
    public init?(hexString: String) {
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
    public func hexEncodedString() -> String {
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
