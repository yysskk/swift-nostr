import Foundation

/// Errors that can occur in the Nostr client
public enum NostrError: Error, LocalizedError, Sendable, Equatable {
    case invalidPrivateKey
    case invalidPublicKey
    case invalidSignature
    case invalidEventId
    case signingFailed
    case signerNotSet
    case verificationFailed
    case serializationFailed
    case invalidData
    case invalidMessageFormat
    case connectionFailed(String)
    case notConnected
    case subscriptionNotFound(String)
    case relayError(String)
    case authenticationFailed(String)
    case cannotPublishAuthenticationEvent
    case timeout
    case invalidHex
    case invalidBech32
    case unknownPrefix(String)
    case invalidTLV
    case invalidNIP19Entity
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
        }
    }
}
