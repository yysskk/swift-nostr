import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Internet Identifier verification (NIP-05)
/// https://github.com/nostr-protocol/nips/blob/master/05.md
///
/// Provides DNS-based verification of Nostr identities using
/// human-readable identifiers like "alice@example.com"
public struct InternetIdentifier: Sendable {

    /// A verified internet identifier result
    public struct VerificationResult: Sendable, Hashable {
        /// The full identifier (e.g., "alice@example.com")
        public let identifier: String

        /// The verified public key (hex)
        public let pubkey: String

        /// Optional relay URLs recommended for this user
        public let relays: [String]

        public init(identifier: String, pubkey: String, relays: [String] = []) {
            self.identifier = identifier
            self.pubkey = pubkey
            self.relays = relays
        }
    }

    /// Errors that can occur during verification
    public enum VerificationError: Error, LocalizedError, Sendable, Equatable {
        case invalidIdentifier
        case networkError(String)
        case invalidResponse
        case pubkeyNotFound
        case pubkeyMismatch

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier:
                return "Invalid internet identifier format"
            case .networkError(let message):
                return "Network error: \(message)"
            case .invalidResponse:
                return "Invalid response from server"
            case .pubkeyNotFound:
                return "Public key not found for identifier"
            case .pubkeyMismatch:
                return "Public key does not match"
            }
        }
    }

    /// Parses an internet identifier into name and domain components
    /// - Parameter identifier: The identifier (e.g., "alice@example.com" or "_@example.com")
    /// - Returns: Tuple of (name, domain)
    public static func parse(_ identifier: String) -> (name: String, domain: String)? {
        let parts = identifier.split(separator: "@", maxSplits: 1)

        if parts.count == 2 {
            return (String(parts[0]), String(parts[1]))
        } else if parts.count == 1 && !identifier.contains("@") {
            // Domain only, use "_" as name
            return ("_", String(parts[0]))
        }

        return nil
    }

    /// Constructs the well-known URL for verification
    /// - Parameters:
    ///   - name: The local part of the identifier
    ///   - domain: The domain
    /// - Returns: The URL to query
    public static func wellKnownURL(name: String, domain: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = domain
        components.path = "/.well-known/nostr.json"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    /// Verifies an internet identifier and returns the associated public key
    /// - Parameter identifier: The identifier (e.g., "alice@example.com")
    /// - Returns: The verification result containing pubkey and optional relays
    public static func verify(_ identifier: String) async throws -> VerificationResult {
        guard let (name, domain) = parse(identifier) else {
            throw VerificationError.invalidIdentifier
        }

        guard let url = wellKnownURL(name: name, domain: domain) else {
            throw VerificationError.invalidIdentifier
        }

        let response: InternetIdentifierResponse
        do {
            let (data, urlResponse) = try await URLSession.shared.data(from: url)

            guard let httpResponse = urlResponse as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                throw VerificationError.invalidResponse
            }

            response = try JSONDecoder().decode(InternetIdentifierResponse.self, from: data)
        } catch let error as VerificationError {
            throw error
        } catch is DecodingError {
            throw VerificationError.invalidResponse
        } catch {
            throw VerificationError.networkError(error.localizedDescription)
        }

        guard let pubkey = response.names[name.lowercased()] ?? response.names[name] else {
            throw VerificationError.pubkeyNotFound
        }

        let relays = response.relays?[pubkey] ?? []

        return VerificationResult(
            identifier: identifier,
            pubkey: pubkey,
            relays: relays
        )
    }

    /// Verifies an internet identifier matches an expected public key
    /// - Parameters:
    ///   - identifier: The identifier
    ///   - expectedPubkey: The expected public key (hex)
    /// - Returns: The verification result if successful
    public static func verify(_ identifier: String, expectedPubkey: String) async throws -> VerificationResult {
        let result = try await verify(identifier)

        guard result.pubkey.lowercased() == expectedPubkey.lowercased() else {
            throw VerificationError.pubkeyMismatch
        }

        return result
    }

    /// Looks up a public key from an internet identifier
    /// - Parameter identifier: The identifier
    /// - Returns: The public key (hex) if found
    public static func lookupPubkey(_ identifier: String) async throws -> String {
        let result = try await verify(identifier)
        return result.pubkey
    }

    /// Looks up recommended relays for an internet identifier
    /// - Parameter identifier: The identifier
    /// - Returns: Array of relay URLs
    public static func lookupRelays(_ identifier: String) async throws -> [String] {
        let result = try await verify(identifier)
        return result.relays
    }
}

// MARK: - Response Model

/// Internal model for the JSON response
private struct InternetIdentifierResponse: Codable {
    let names: [String: String]
    let relays: [String: [String]]?
}

// MARK: - String Extension

extension String {
    /// Returns true if this string appears to be a valid internet identifier format
    public var isValidInternetIdentifier: Bool {
        InternetIdentifier.parse(self) != nil
    }

    /// Verifies this string as an internet identifier
    public func verifyAsInternetIdentifier() async throws -> InternetIdentifier.VerificationResult {
        try await InternetIdentifier.verify(self)
    }

    /// Verifies this string as an internet identifier against an expected pubkey
    public func verifyAsInternetIdentifier(expectedPubkey: String) async throws -> InternetIdentifier.VerificationResult
    {
        try await InternetIdentifier.verify(self, expectedPubkey: expectedPubkey)
    }
}
