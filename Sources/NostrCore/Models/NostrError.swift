import Foundation

/// Errors that can occur in the Nostr client
public enum NostrError: Error, LocalizedError, Sendable, Equatable {
    case invalidEventID
    case signerNotSet
    case verificationFailed
    case serializationFailed
    case invalidData
    case connectionFailed(String)
    case notConnected
    case relayError(String)
    /// A relay-targeted operation ran against an empty pool.
    case noRelaysInPool
    /// None of the requested relay URLs are in the pool (payload: the requested URLs, sorted).
    case noMatchingRelays([RelayURL])
    case authenticationFailed(String)
    case cannotPublishAuthenticationEvent
    case timeout
    case unknownPrefix(String)
    case invalidTLV
    case invalidNIP19Entity
    case invalidNostrURI
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidEventID:
            return "Invalid event ID"
        case .signerNotSet:
            return "No signer is set — call setSigner(_:), setPrivateKey(_:), or setNsec(_:) first"
        case .verificationFailed:
            return "Signature verification failed"
        case .serializationFailed:
            return "Failed to serialize data"
        case .invalidData:
            return "Invalid data"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .notConnected:
            return "Not connected to relay"
        case .relayError(let message):
            return "Relay error: \(message)"
        case .noRelaysInPool:
            return "The relay pool is empty — add relays with addRelay(_:) or connect(to:) first"
        case .noMatchingRelays(let requested):
            if requested.isEmpty {
                return "The target relay list is empty"
            }
            return
                "None of the targeted relays are in the pool: \(requested.map(\.description).joined(separator: ", "))"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .cannotPublishAuthenticationEvent:
            return
                "NIP-42 authentication events (kind 22242) must not be published; they are only sent as AUTH responses"
        case .timeout:
            return "Operation timed out"
        case .unknownPrefix(let prefix):
            return "Unknown bech32 prefix: \(prefix)"
        case .invalidTLV:
            return "Invalid TLV encoding"
        case .invalidNIP19Entity:
            return "Invalid NIP-19 entity"
        case .invalidNostrURI:
            return "Invalid nostr: URI"
        case .decryptionFailed:
            return "Decryption failed"
        }
    }
}
