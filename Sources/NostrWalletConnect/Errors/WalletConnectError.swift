import Foundation
public import NostrCore

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

    /// The task awaiting the wallet was cancelled. A request cancelled after it was sent may still
    /// be carried out by the wallet.
    case cancelled

    /// The relay transport failed to connect, subscribe, or send.
    case transportFailed(RelayConnection.Error)

    /// The wallet response carried neither a `result` nor an `error`.
    case missingResult

    /// The wallet answered with a `result_type` naming a different command than the one requested.
    case unexpectedResultType(expected: WalletConnectMethod, received: WalletConnectMethod)

    /// The wallet encrypted its response with a scheme this package does not implement.
    case unsupportedEncryption(String)

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
        case .cancelled:
            return "The wallet operation was cancelled"
        case .transportFailed(let error):
            return "The wallet relay transport failed: \(error.errorDescription ?? "\(error)")"
        case .missingResult:
            return "The wallet response contained neither a result nor an error"
        case .unexpectedResultType(let expected, let received):
            return "The wallet answered a \(expected) request with a \(received) response"
        case .unsupportedEncryption(let scheme):
            return "The wallet response uses an unsupported encryption scheme: \(scheme)"
        case .walletError(let code, let message):
            return "Wallet error (\(code.rawValue)): \(message)"
        }
    }
}

/// A NIP-47 error code.
///
/// The set is open-ended: the codes NIP-47 defines are available as static constants, and any code
/// a wallet sends — including one a future revision adds — is preserved verbatim through
/// ``init(rawValue:)``. The value encodes to and from JSON as a bare string.
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public struct WalletConnectErrorCode: RawRepresentable, Codable, Sendable, Hashable, CustomStringConvertible {
    /// The wire code string.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String {
        rawValue
    }

    /// The client is sending commands too fast (`RATE_LIMITED`).
    public static let rateLimited = WalletConnectErrorCode(rawValue: "RATE_LIMITED")
    /// The command is not known or is intentionally not implemented (`NOT_IMPLEMENTED`).
    public static let notImplemented = WalletConnectErrorCode(rawValue: "NOT_IMPLEMENTED")
    /// The wallet does not have enough funds (`INSUFFICIENT_BALANCE`).
    public static let insufficientBalance = WalletConnectErrorCode(rawValue: "INSUFFICIENT_BALANCE")
    /// The wallet has exceeded its spending quota (`QUOTA_EXCEEDED`).
    public static let quotaExceeded = WalletConnectErrorCode(rawValue: "QUOTA_EXCEEDED")
    /// This public key is not allowed to do this operation (`RESTRICTED`).
    public static let restricted = WalletConnectErrorCode(rawValue: "RESTRICTED")
    /// This public key has no wallet connected (`UNAUTHORIZED`).
    public static let unauthorized = WalletConnectErrorCode(rawValue: "UNAUTHORIZED")
    /// An internal wallet error (`INTERNAL`).
    public static let `internal` = WalletConnectErrorCode(rawValue: "INTERNAL")
    /// The wallet does not support the request's encryption scheme (`UNSUPPORTED_ENCRYPTION`).
    public static let unsupportedEncryption = WalletConnectErrorCode(rawValue: "UNSUPPORTED_ENCRYPTION")
    /// The payment failed, e.g. no route was found (`PAYMENT_FAILED`).
    public static let paymentFailed = WalletConnectErrorCode(rawValue: "PAYMENT_FAILED")
    /// Any other error (`OTHER`).
    public static let other = WalletConnectErrorCode(rawValue: "OTHER")
}
