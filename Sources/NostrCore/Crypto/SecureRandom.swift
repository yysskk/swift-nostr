import Foundation

/// Provides cryptographically secure random byte generation
enum SecureRandom {
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
}
