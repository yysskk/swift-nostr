import Foundation
import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A NIP-05 internet identifier, such as `alice@example.com`, which a domain maps to a public key.
/// https://github.com/nostr-protocol/nips/blob/master/05.md
///
/// Creating one validates the string; ``verify()`` then asks the domain which key the name maps to:
///
/// ```swift
/// guard let identifier = InternetIdentifier("alice@example.com") else { return }
/// let result = try await identifier.verify()
/// print(result.publicKey, result.relays)
/// ```
///
/// The separator is the *last* `@`, and the local part (``name``) must use the `a-z0-9-_.` NIP-05
/// allows (uppercase included, since ``verify()`` looks the name up both as written and
/// lowercased). A string carrying more than one `@` is therefore rejected rather than resolved:
/// `alice@evil.com@example.com` would otherwise name a different server than a reader expects.
/// A domain alone, such as `example.com`, is the root identifier `_@example.com`.
///
/// The ``domain`` is lowercased, since hosts are case-insensitive; ``name`` keeps its case.
/// ``description`` is `name@domain`, and the value encodes to and from JSON as that string.
public struct InternetIdentifier: Sendable, Hashable {
    /// The local part, such as `alice`; `_` for the root identifier of a domain.
    public let name: String

    /// The domain that serves the identifier's `nostr.json`, lowercased.
    public let domain: String

    /// The URL of the `nostr.json` document that resolves ``name``:
    /// `https://<domain>/.well-known/nostr.json?name=<name>`.
    public let wellKnownURL: URL

    /// Errors that can occur during verification
    public enum VerificationError: Error, LocalizedError, Sendable, Equatable {
        /// The `nostr.json` request failed; carries the underlying error's description.
        case networkError(String)
        /// The server answered with a non-2xx status or a body that is not a `nostr.json` document.
        case invalidResponse
        /// The document has no canonical hex public key for the name.
        case publicKeyNotFound
        /// The identifier resolves to a public key other than the expected one.
        case publicKeyMismatch

        public var errorDescription: String? {
            switch self {
            case .networkError(let message):
                return "Network error: \(message)"
            case .invalidResponse:
                return "Invalid response from server"
            case .publicKeyNotFound:
                return "Public key not found for identifier"
            case .publicKeyMismatch:
                return "Public key does not match"
            }
        }
    }

    /// A verified internet identifier result
    public struct VerificationResult: Sendable, Hashable {
        /// The identifier that was verified.
        public let identifier: InternetIdentifier

        /// The verified public key
        public let publicKey: PublicKey

        /// Relay URLs the server recommends for this user, in the order listed. The server's
        /// `relays` entries are third-party content, so one that is not a valid relay URL is
        /// skipped.
        public let relays: [RelayURL]

        /// Creates a verification result.
        /// - Parameters:
        ///   - identifier: The identifier that was verified.
        ///   - publicKey: The public key the identifier resolved to.
        ///   - relays: Relay URLs the server recommends for this user.
        public init(identifier: InternetIdentifier, publicKey: PublicKey, relays: [RelayURL] = []) {
            self.identifier = identifier
            self.publicKey = publicKey
            self.relays = relays
        }
    }

    /// Asks ``domain`` which public key ``name`` maps to.
    ///
    /// The server's `names` entry must be a canonical hex public key (64 lowercase hex digits, as
    /// NIP-05 requires); any other value names no key, so it is reported as
    /// ``VerificationError/publicKeyNotFound``.
    /// - Returns: The public key and the relays the server recommends for it.
    /// - Throws: ``VerificationError/networkError(_:)``, ``VerificationError/invalidResponse``, or
    ///   ``VerificationError/publicKeyNotFound``.
    public func verify() async throws(VerificationError) -> VerificationResult {
        let data: Data
        do {
            let (body, urlResponse) = try await URLSession.shared.data(from: wellKnownURL)

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

        return try result(in: data)
    }

    /// Verifies that the identifier maps to `expectedPublicKey`, as when checking the `nip05` a
    /// profile claims.
    /// - Parameter expectedPublicKey: The key the identifier must resolve to.
    /// - Returns: The verification result.
    /// - Throws: Anything ``verify()`` throws, or ``VerificationError/publicKeyMismatch`` when the
    ///   identifier resolves to a different key.
    public func verify(expectedPublicKey: PublicKey) async throws(VerificationError) -> VerificationResult {
        let result = try await verify()

        guard result.publicKey == expectedPublicKey else {
            throw VerificationError.publicKeyMismatch
        }

        return result
    }

    /// Resolves ``name`` in a `nostr.json` document served for this identifier.
    ///
    /// The document is third-party data: a `names` value that is not a canonical hex public key
    /// is treated as absent.
    /// - Throws: ``VerificationError/invalidResponse`` if `data` is not a `nostr.json` document, or
    ///   ``VerificationError/publicKeyNotFound`` if it has no usable key for ``name``.
    func result(in data: Data) throws(VerificationError) -> VerificationResult {
        let response: InternetIdentifierResponse
        do {
            response = try JSONDecoder().decode(InternetIdentifierResponse.self, from: data)
        } catch {
            throw VerificationError.invalidResponse
        }

        guard let hex = response.names[name.lowercased()] ?? response.names[name],
            let publicKey = PublicKey(hex)
        else {
            throw VerificationError.publicKeyNotFound
        }

        return VerificationResult(
            identifier: self,
            publicKey: publicKey,
            relays: (response.relays?[publicKey.hex] ?? []).compactMap(RelayURL.init)
        )
    }
}

extension InternetIdentifier: CustomStringConvertible, LosslessStringConvertible {
    /// The identifier as `name@domain`; the root identifier of a domain is `_@domain`.
    public var description: String {
        "\(name)@\(domain)"
    }

    /// Creates an identifier from `name@domain`, or from a bare domain for its root identifier
    /// `_@domain`, or returns `nil` if the string is not a well-formed identifier.
    /// - Parameter description: The identifier, such as `alice@example.com` or `example.com`.
    public init?(_ description: String) {
        let name: String
        let domain: String
        if let separator = description.lastIndex(of: "@") {
            name = String(description[..<separator])
            domain = String(description[description.index(after: separator)...])
        } else {
            name = "_"
            domain = description
        }

        guard Self.isValidName(name), Self.isValidDomain(domain) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = domain.lowercased()
        components.path = "/.well-known/nostr.json"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else {
            return nil
        }

        self.name = name
        self.domain = domain.lowercased()
        self.wellKnownURL = url
    }

    /// NIP-05 restricts the local part to `a-z0-9-_.`; uppercase is tolerated here because
    /// ``verify()`` looks the name up both as written and lowercased.
    private static func isValidName(_ name: String) -> Bool {
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
}

extension InternetIdentifier: Codable {
    /// Decodes an identifier from its string form.
    /// - Throws: `DecodingError.dataCorrupted` if the string is not a well-formed identifier.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let value = InternetIdentifier(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "An internet identifier must be name@domain or a domain")
        }
        self = value
    }

    /// Encodes the identifier as ``description``.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - Response Model

/// Internal model for the JSON response
private struct InternetIdentifierResponse: Codable {
    let names: [String: String]
    let relays: [String: [String]]?
}
