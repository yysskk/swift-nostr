import Foundation

#if canImport(Security)
    import Security
#endif

/// Provides cryptographically secure random byte generation
enum SecureRandom {
    /// Generates cryptographically secure random bytes
    /// - Parameter count: The number of random bytes to generate
    /// - Returns: Data containing the random bytes
    /// - Throws: ``NostrError/randomGenerationFailed`` if the system CSPRNG fails
    static func generateBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)

        #if canImport(Security)
            let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
            guard status == errSecSuccess else {
                throw NostrError.randomGenerationFailed
            }
        #else
            // Fallback for non-Apple platforms (e.g., Linux)
            var generator = SystemRandomNumberGenerator()
            for i in 0..<count {
                bytes[i] = UInt8.random(in: 0...255, using: &generator)
            }
        #endif

        return Data(bytes)
    }
}
