import Foundation
public import NostrCore

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

    /// The task awaiting the remote signer was cancelled. A request cancelled after it was sent may
    /// still be carried out by the signer.
    case cancelled

    /// The relay transport failed to connect, subscribe, or send.
    case transportFailed(RelayConnection.Error)

    /// The remote signer declined the connection, or answered `connect` with neither `"ack"` nor
    /// the secret that was sent. `message` is the result the signer returned, empty when there was
    /// none.
    case connectionRejected(message: String)

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
        case .cancelled:
            return "The remote signer operation was cancelled"
        case .transportFailed(let error):
            return "The remote signer relay transport failed: \(error.errorDescription ?? "\(error)")"
        case .connectionRejected(let message):
            return "The remote signer rejected the connection: \(message)"
        case .signerError(let message):
            return "Remote signer error: \(message)"
        case .responseValidationFailed:
            return "The remote signer response failed validation"
        }
    }
}
