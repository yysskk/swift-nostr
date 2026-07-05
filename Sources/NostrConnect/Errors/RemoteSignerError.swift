import Foundation

/// Errors raised by the NostrConnect module.
public enum RemoteSignerError: Error, LocalizedError, Sendable, Equatable {
    /// A `bunker://` or `nostrconnect://` connection string could not be parsed or failed validation.
    case invalidURI(reason: String)

    /// An operation was attempted before a session was established.
    case notConnected

    /// A ``RemoteSigner/awaitConnection()`` wait is already in progress on this session; only one
    /// may run at a time.
    case connectionInProgress

    /// The request could not be encoded or encrypted.
    case requestEncodingFailed

    /// The response could not be decrypted or decoded.
    case responseDecodingFailed

    /// The remote signer did not respond before the configured timeout elapsed.
    case timedOut

    /// The remote signer declined the connection.
    case connectionRejected(message: String)

    /// The secret returned by the remote signer did not match the one that was sent.
    case secretMismatch

    /// The remote signer returned an explicit error for the request.
    case signerError(message: String)

    /// The response was well-formed but failed validation (e.g. a signature did not verify).
    case responseValidationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURI(let reason):
            return "Invalid Nostr Connect URI: \(reason)"
        case .notConnected:
            return "The remote signer session is not established"
        case .connectionInProgress:
            return "A remote signer connection attempt is already in progress"
        case .requestEncodingFailed:
            return "Failed to encode the remote signer request"
        case .responseDecodingFailed:
            return "Failed to decode the remote signer response"
        case .timedOut:
            return "The remote signer did not respond in time"
        case .connectionRejected(let message):
            return "The remote signer rejected the connection: \(message)"
        case .secretMismatch:
            return "The remote signer returned a secret that did not match"
        case .signerError(let message):
            return "Remote signer error: \(message)"
        case .responseValidationFailed:
            return "The remote signer response failed validation"
        }
    }
}
