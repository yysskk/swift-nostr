import Foundation

/// The connection state of a ``RelayConnection``, observed through ``RelayConnection/state`` and
/// ``RelayConnection/stateChanges()``.
public enum RelayConnectionState: Sendable, Hashable {
    /// No connection is open, and none is being opened.
    case disconnected
    /// A connection attempt is in progress.
    case connecting
    /// The socket is open and answered the verifying ping.
    case connected
    /// The connection is being closed on request.
    case disconnecting
    /// A connection attempt failed or a live connection dropped; the payload says what failed.
    ///
    /// The connection reconnects from here when ``RelayConnectionConfig/reconnect`` allows it, and
    /// ``RelayConnection/connect()`` starts a fresh attempt.
    case failed(Failure)
}

extension RelayConnectionState {
    /// Why a ``RelayConnection`` entered ``RelayConnectionState/failed(_:)``.
    ///
    /// ```swift
    /// for await state in await connection.stateChanges() {
    ///     if case .failed(let failure) = state, failure.operation == .keepalive {
    ///         print("Relay stopped answering pings: \(failure.reason)")
    ///     }
    /// }
    /// ```
    public struct Failure: Swift.Error, LocalizedError, Sendable, Hashable {
        /// The operation that failed.
        public enum Operation: Sendable, Hashable {
            /// Opening the socket, or the ping that verifies it, failed or timed out.
            case connect
            /// A keepalive ping on a live connection failed or went unanswered.
            case keepalive
            /// Writing a frame to the socket failed or outlasted
            /// ``RelayConnectionConfig/sendTimeout``.
            case send
            /// The socket reported an error while waiting for the next frame.
            case receive
        }

        /// The operation that failed.
        public let operation: Operation

        /// The description of the underlying error, such as the socket's or
        /// ``RelayConnection/Error/timedOut``'s.
        public let reason: String

        /// Creates a failure — for a stub of a connection's state; a connection builds its own.
        /// - Parameters:
        ///   - operation: The operation that failed.
        ///   - reason: The description of the underlying error.
        public init(operation: Operation, reason: String) {
            self.operation = operation
            self.reason = reason
        }

        /// A failure of `operation` caused by `error`.
        init(_ operation: Operation, error: any Swift.Error) {
            self.init(operation: operation, reason: error.localizedDescription)
        }

        public var errorDescription: String? {
            switch operation {
            case .connect:
                return "Could not connect to the relay: \(reason)"
            case .keepalive:
                return "The relay stopped answering keepalive pings: \(reason)"
            case .send:
                return "Could not send to the relay: \(reason)"
            case .receive:
                return "The connection to the relay dropped: \(reason)"
            }
        }
    }
}
