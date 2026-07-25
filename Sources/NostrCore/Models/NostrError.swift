import Foundation

/// Errors that can occur in the Nostr client
public enum NostrError: Error, LocalizedError, Sendable, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case invalidEventId
    case signingFailed
    case signerNotSet
    case localSignerRequired
    case verificationFailed
    case serializationFailed
    case invalidData
    case invalidMessageFormat
    case connectionFailed(String)
    case notConnected
    case subscriptionNotFound(String)
    case relayError(String)
    /// A relay-targeted operation ran against an empty pool.
    case noRelaysInPool
    /// None of the requested relay URLs are in the pool (payload: the normalized requested URLs).
    case noMatchingRelays([String])
    case authenticationFailed(String)
    case cannotPublishAuthenticationEvent
    case timeout
    case invalidHex
    case invalidBech32
    case unknownPrefix(String)
    case invalidTLV
    case invalidNIP19Entity
    case invalidNostrURI
    case encryptionFailed
    case decryptionFailed
    case unsupportedEncryptionVersion(UInt8)
    case invalidPayloadFormat
    case hmacVerificationFailed
    case invalidPadding
    case invalidMnemonic
    case invalidMnemonicWord(String)
    case invalidMnemonicChecksum
    case randomGenerationFailed
    case invalidNcryptsec
    case unsupportedScryptCost(UInt8)

    public var errorDescription: String? {
        switch self {
        case .invalidPrivateKey:
            return "Invalid private key"
        case .invalidPublicKey:
            return "Invalid public key"
        case .invalidSignature:
            return "Invalid signature"
        case .invalidEventId:
            return "Invalid event ID"
        case .signingFailed:
            return "Failed to sign event"
        case .signerNotSet:
            return "No signer is set — call setSigner(_:), setPrivateKey(_:), or setNsec(_:) first"
        case .localSignerRequired:
            return "This operation requires a local signing key (a remote signer cannot perform it)"
        case .verificationFailed:
            return "Signature verification failed"
        case .serializationFailed:
            return "Failed to serialize data"
        case .invalidData:
            return "Invalid data"
        case .invalidMessageFormat:
            return "Invalid message format"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .notConnected:
            return "Not connected to relay"
        case .subscriptionNotFound(let id):
            return "Subscription not found: \(id)"
        case .relayError(let message):
            return "Relay error: \(message)"
        case .noRelaysInPool:
            return "The relay pool is empty — add relays with addRelay(_:) or connect(to:) first"
        case .noMatchingRelays(let requested):
            if requested.isEmpty {
                return "The target relay list is empty"
            }
            return "None of the targeted relays are in the pool: \(requested.joined(separator: ", "))"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        case .cannotPublishAuthenticationEvent:
            return
                "NIP-42 authentication events (kind 22242) must not be published; they are only sent as AUTH responses"
        case .timeout:
            return "Operation timed out"
        case .invalidHex:
            return "Invalid hexadecimal string"
        case .invalidBech32:
            return "Invalid bech32 encoding"
        case .unknownPrefix(let prefix):
            return "Unknown bech32 prefix: \(prefix)"
        case .invalidTLV:
            return "Invalid TLV encoding"
        case .invalidNIP19Entity:
            return "Invalid NIP-19 entity"
        case .invalidNostrURI:
            return "Invalid nostr: URI"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .unsupportedEncryptionVersion(let version):
            return "Unsupported encryption version: \(version)"
        case .invalidPayloadFormat:
            return "Invalid encrypted payload format"
        case .hmacVerificationFailed:
            return "HMAC verification failed"
        case .invalidPadding:
            return "Invalid message padding"
        case .invalidMnemonic:
            return "Invalid mnemonic phrase"
        case .invalidMnemonicWord(let word):
            return "Invalid mnemonic word: \(word)"
        case .invalidMnemonicChecksum:
            return "Invalid mnemonic checksum"
        case .randomGenerationFailed:
            return "Failed to generate secure random bytes"
        case .invalidNcryptsec:
            return "The ncryptsec payload is malformed or has an unsupported version"
        case .unsupportedScryptCost:
            return "The ncryptsec declares an unsupported scrypt cost"
        }
    }
}
