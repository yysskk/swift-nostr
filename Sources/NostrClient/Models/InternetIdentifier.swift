import Foundation
import NostrCore

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

        /// The verified public key
        public let pubkey: PublicKey

        /// Optional relay URLs recommended for this user
        public let relays: [String]

        /// Creates a verification result.
        /// - Parameters:
        ///   - identifier: The full identifier (e.g., "alice@example.com").
        ///   - pubkey: The public key the identifier resolved to.
        ///   - relays: Relay URLs the server recommends for this user.
        public init(identifier: String, pubkey: PublicKey, relays: [String] = []) {
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

    /// Parses an internet identifier into name and domain components.
    ///
    /// The separator is the *last* `@`, matching how `LNURL` resolves the same identifier shape, and
    /// the local part must be the `a-z0-9-_.` NIP-05 allows (uppercase included, since
    /// ``verify(_:)`` looks the name up in both cases). A string carrying more than one `@` is
    /// therefore rejected rather than resolved: splitting on the first one made
    /// `alice@evil.com@example.com` look like the host `evil.com@example.com`, which names a
    /// different server than a reader of that identifier would expect.
    /// - Parameter identifier: The identifier (e.g., "alice@example.com" or "_@example.com")
    /// - Returns: Tuple of (name, domain), or nil if the identifier is not well formed.
    public static func parse(_ identifier: String) -> (name: String, domain: String)? {
        let name: String
        let domain: String

        if let separator = identifier.lastIndex(of: "@") {
            name = String(identifier[identifier.startIndex..<separator])
            domain = String(identifier[identifier.index(after: separator)...])
        } else {
            // Domain only, use "_" as name
            name = "_"
            domain = identifier
        }

        guard isValidLocalPart(name), isValidDomain(domain) else {
            return nil
        }

        return (name, domain)
    }

    /// NIP-05 restricts the local part to `a-z0-9-_.`; uppercase is tolerated here because
    /// ``verify(_:)`` looks the name up both as written and lowercased.
    private static func isValidLocalPart(_ name: String) -> Bool {
        !name.isEmpty
            && name.allSatisfy { character in
                character.isASCII
                    && (character.isLetter || character.isNumber || "-_.".contains(character))
            }
    }

    /// Rejects anything that would not survive being placed in a URL's host component, so a
    /// malformed identifier fails here rather than by silently querying the wrong server.
    private static func isValidDomain(_ domain: String) -> Bool {
        !domain.isEmpty
            && !domain.contains("@")
            && !domain.contains("/")
            && !domain.contains(":")
            && domain.allSatisfy { $0.isASCII && !$0.isWhitespace }
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
    ///
    /// The server's `names` entry must be a canonical hex public key (64 lowercase hex digits, as
    /// NIP-05 requires); any other value names no key, so it is reported as
    /// ``VerificationError/pubkeyNotFound``.
    /// - Parameter identifier: The identifier (e.g., "alice@example.com")
    /// - Returns: The verification result containing pubkey and optional relays
    public static func verify(_ identifier: String) async throws -> VerificationResult {
        guard let (name, domain) = parse(identifier) else {
            throw VerificationError.invalidIdentifier
        }

        guard let url = wellKnownURL(name: name, domain: domain) else {
            throw VerificationError.invalidIdentifier
        }

        let data: Data
        do {
            let (body, urlResponse) = try await URLSession.shared.data(from: url)

            guard let httpResponse = urlResponse as? HTTPURLResponse,
                (200...299).contains(httpResponse.statusCode)
            else {
                throw VerificationError.invalidResponse
            }
            data = body
        } catch let error as VerificationError {
            throw error
        } catch {
            throw VerificationError.networkError(error.localizedDescription)
        }

        return try result(for: identifier, name: name, in: data)
    }

    /// Resolves `name` in a `nostr.json` document served for `identifier`.
    ///
    /// The document is third-party data: a `names` value that is not a canonical hex public key
    /// is treated as absent.
    /// - Throws: ``VerificationError/invalidResponse`` if `data` is not a `nostr.json` document, or
    ///   ``VerificationError/pubkeyNotFound`` if it has no usable key for `name`.
    static func result(for identifier: String, name: String, in data: Data) throws -> VerificationResult {
        let response: InternetIdentifierResponse
        do {
            response = try JSONDecoder().decode(InternetIdentifierResponse.self, from: data)
        } catch {
            throw VerificationError.invalidResponse
        }

        guard let hex = response.names[name.lowercased()] ?? response.names[name],
            let pubkey = PublicKey(hex)
        else {
            throw VerificationError.pubkeyNotFound
        }

        return VerificationResult(
            identifier: identifier,
            pubkey: pubkey,
            relays: response.relays?[pubkey.hex] ?? []
        )
    }

    /// Verifies an internet identifier matches an expected public key
    /// - Parameters:
    ///   - identifier: The identifier
    ///   - expectedPubkey: The expected public key
    /// - Returns: The verification result if successful
    public static func verify(_ identifier: String, expectedPubkey: PublicKey) async throws -> VerificationResult {
        let result = try await verify(identifier)

        guard result.pubkey == expectedPubkey else {
            throw VerificationError.pubkeyMismatch
        }

        return result
    }

    /// Looks up a public key from an internet identifier
    /// - Parameter identifier: The identifier
    /// - Returns: The public key the identifier resolves to
    public static func lookupPubkey(_ identifier: String) async throws -> PublicKey {
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
    public func verifyAsInternetIdentifier(expectedPubkey: PublicKey) async throws -> InternetIdentifier.VerificationResult
    {
        try await InternetIdentifier.verify(self, expectedPubkey: expectedPubkey)
    }
}
