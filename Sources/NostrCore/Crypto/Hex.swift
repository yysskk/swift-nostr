import Foundation

// MARK: - Hexadecimal Encoding

extension Data {
    /// Creates data by decoding a hexadecimal string.
    ///
    /// The string must contain an even number of hexadecimal digits; decoding is
    /// case-insensitive. Returns `nil` if the string has an odd length or
    /// contains a non-hex character.
    public init?(hexString: String) {
        let hex = hexString.lowercased()
        guard hex.count % 2 == 0 else { return nil }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex

        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else {
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
