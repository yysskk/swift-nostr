import Foundation

/// Errors raised by the NostrWalletConnect module.
public enum WalletConnectError: Error, LocalizedError, Sendable, Equatable {
    /// A `nostr+walletconnect://` connection string could not be parsed or failed validation.
    case invalidURI(reason: String)

    /// An operation was attempted before the connection was established.
    case notConnected

    /// The request could not be encoded or encrypted.
    case requestEncodingFailed

    /// The response could not be decrypted or decoded.
    case responseDecodingFailed

    /// The wallet did not respond before the configured timeout elapsed.
    case timedOut

    /// A pending operation was superseded by a newer one (e.g. a concurrent `fetchInfo()`).
    case superseded

    /// The wallet response carried neither a `result` nor an `error`.
    case missingResult

    /// The wallet returned an explicit error for the request.
    case walletError(code: WalletConnectErrorCode, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidURI(let reason):
            return "Invalid Nostr Wallet Connect URI: \(reason)"
        case .notConnected:
            return "The wallet connection is not established"
        case .requestEncodingFailed:
            return "Failed to encode the wallet request"
        case .responseDecodingFailed:
            return "Failed to decode the wallet response"
        case .timedOut:
            return "The wallet did not respond in time"
        case .superseded:
            return "The operation was superseded by a newer one"
        case .missingResult:
            return "The wallet response contained neither a result nor an error"
        case .walletError(let code, let message):
            return "Wallet error (\(code.rawValue)): \(message)"
        }
    }
}

/// A NIP-47 error code.
///
/// The standard codes are modeled as cases; any code a wallet sends that is not in the spec is
/// preserved verbatim as ``unknown(_:)``. The non-failable `init(rawValue:)` (unknown codes fall
/// back to ``unknown(_:)``) satisfies `RawRepresentable`'s failable requirement.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public enum WalletConnectErrorCode: RawRepresentable, Sendable, Equatable {
    public typealias RawValue = String

    case rateLimited
    case notImplemented
    case insufficientBalance
    case quotaExceeded
    case restricted
    case unauthorized
    case `internal`
    case unsupportedEncryption
    case paymentFailed
    case other
    case unknown(String)

    /// Maps a wire code string to a case, preserving unrecognized codes as ``unknown(_:)``.
    public init(rawValue: String) {
        switch rawValue {
        case "RATE_LIMITED": self = .rateLimited
        case "NOT_IMPLEMENTED": self = .notImplemented
        case "INSUFFICIENT_BALANCE": self = .insufficientBalance
        case "QUOTA_EXCEEDED": self = .quotaExceeded
        case "RESTRICTED": self = .restricted
        case "UNAUTHORIZED": self = .unauthorized
        case "INTERNAL": self = .internal
        case "UNSUPPORTED_ENCRYPTION": self = .unsupportedEncryption
        case "PAYMENT_FAILED": self = .paymentFailed
        case "OTHER": self = .other
        default: self = .unknown(rawValue)
        }
    }

    /// The wire code string for this case.
    public var rawValue: String {
        switch self {
        case .rateLimited: return "RATE_LIMITED"
        case .notImplemented: return "NOT_IMPLEMENTED"
        case .insufficientBalance: return "INSUFFICIENT_BALANCE"
        case .quotaExceeded: return "QUOTA_EXCEEDED"
        case .restricted: return "RESTRICTED"
        case .unauthorized: return "UNAUTHORIZED"
        case .internal: return "INTERNAL"
        case .unsupportedEncryption: return "UNSUPPORTED_ENCRYPTION"
        case .paymentFailed: return "PAYMENT_FAILED"
        case .other: return "OTHER"
        case .unknown(let raw): return raw
        }
    }
}
