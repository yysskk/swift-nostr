import Foundation

/// Provides cryptographically secure random byte generation
package enum SecureRandom {
    /// Generates cryptographically secure random bytes
    ///
    /// Draws from `SystemRandomNumberGenerator`, the operating system's CSPRNG on every platform.
    /// The standard library traps rather than returning weak bytes if that source ever fails, so
    /// there is no error to report.
    /// - Parameter count: The number of random bytes to generate
    /// - Returns: Data containing the random bytes
    static func generateBytes(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in generator.next() as UInt8 })
    }

    /// Returns `byteCount` random bytes from the system CSPRNG as a lowercase hex string, for
    /// identifiers and secrets that travel as text, such as NIP-46 request ids and connection
    /// secrets.
    /// - Parameter byteCount: The number of random bytes; the string has twice as many characters.
    package static func hex(byteCount: Int) -> String {
        generateBytes(count: byteCount).hexEncodedString()
    }
}
