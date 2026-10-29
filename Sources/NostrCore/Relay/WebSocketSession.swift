import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A single WebSocket frame exchanged with a relay.
///
/// Mirrors the two frame kinds a relay can send or receive. Nostr's relay protocol is
/// entirely text (JSON), so ``string(_:)`` carries every protocol message; ``data(_:)``
/// is modeled for completeness.
public enum WebSocketMessage: Sendable, Equatable {
    /// A UTF-8 text frame.
    case string(String)
    /// A binary frame.
    case data(Data)
}

/// A WebSocket close code, as defined by RFC 6455 §7.4.1.
///
/// Raw values are the on-the-wire status codes, so a transport can map to and from its
/// platform's native close-code type (`URLSessionWebSocketTask.CloseCode`, OkHttp's
/// integer codes, …) via `RawRepresentable`.
public enum WebSocketCloseCode: Int, Sendable {
    case normalClosure = 1000
    case goingAway = 1001
    case protocolError = 1002
    case unsupportedData = 1003
    case noStatusReceived = 1005
    case abnormalClosure = 1006
    case invalidFramePayloadData = 1007
    case policyViolation = 1008
    case messageTooBig = 1009
    case mandatoryExtensionMissing = 1010
    case internalServerError = 1011
    case tlsHandshakeFailure = 1015
}

/// A WebSocket transport for a relay connection.
///
/// Abstracting the socket behind this protocol lets a relay connection's state machine —
/// connect, receive, keepalive, and reconnect — run on any transport:
///
/// - the default `URLSession`-backed ``URLSessionWebSocketFactory`` on Apple platforms,
/// - an in-memory fake in tests, so the logic can be exercised without a live relay, or
/// - a host-supplied native socket (for example OkHttp on Android) injected through the
///   ``WebSocketSessionFactory``.
///
/// The protocol deliberately avoids `URLSessionWebSocketTask` types (``WebSocketMessage``
/// and ``WebSocketCloseCode`` stand in for them) so it compiles on platforms whose
/// Foundation lacks WebSocket support, such as Android.
///
/// ## Implementing a transport
///
/// A relay connection calls ``open()`` once, right after the factory creates the session, and
/// then verifies the handshake with ``ping()`` before it reports itself connected. Callback-based
/// platform sockets bridge into the async requirements with a checked continuation:
///
/// ```swift
/// final class PlatformWebSocket: WebSocketSession, @unchecked Sendable {
///     private let socket: PlatformSocket  // the platform's own WebSocket client
///
///     func open() { socket.connect() }
///
///     func close(code: WebSocketCloseCode, reason: String?) {
///         socket.close(code: code.rawValue, reason: reason)
///     }
///
///     func send(_ message: WebSocketMessage) async throws { /* … */ }
///
///     func receive() async throws -> WebSocketMessage { /* … */ }
///
///     func ping() async throws {
///         try await withCheckedThrowingContinuation { continuation in
///             socket.ping { error in  // called once, when the pong arrives or the ping fails
///                 if let error {
///                     continuation.resume(throwing: error)
///                 } else {
///                     continuation.resume()
///                 }
///             }
///         }
///     }
/// }
/// ```
///
/// ``ping()`` needs no timeout of its own: the connection bounds every ping with
/// ``RelayConnectionConfig/connectionTimeout`` and stops waiting when it expires, even if the
/// call never returns.
public protocol WebSocketSession: Sendable {
    /// Starts the WebSocket handshake.
    ///
    /// Returns without waiting for the handshake to finish; the connection learns that the socket
    /// is up from the first ``ping()`` that succeeds, and a failed handshake surfaces as an error
    /// from that ping or from ``send(_:)`` and ``receive()``.
    func open()

    /// Closes the socket with the given close code and optional UTF-8 reason.
    ///
    /// Any ``receive()`` still pending must then fail rather than stay suspended. RFC 6455 limits
    /// the reason to 123 bytes of UTF-8.
    func close(code: WebSocketCloseCode, reason: String?)

    /// Sends a single WebSocket frame.
    func send(_ message: WebSocketMessage) async throws

    /// Receives the next WebSocket frame, suspending until one arrives or the socket fails.
    func receive() async throws -> WebSocketMessage

    /// Sends a ping and returns once the matching pong arrives, throwing if the ping fails.
    ///
    /// The connection enforces the pong timeout itself and abandons a ping that outlives it, so an
    /// implementation needs neither a timer nor cancellation support.
    func ping() async throws
}

/// Creates a ``WebSocketSession`` for a request.
///
/// Injected wherever a relay connection is created so a host can supply a platform-native
/// transport (or a test can supply a fake) in place of `URLSession`. The default
/// implementation is ``URLSessionWebSocketFactory``.
public protocol WebSocketSessionFactory: Sendable {
    /// Creates a new, unstarted transport for `request`.
    func makeWebSocket(with request: URLRequest) -> any WebSocketSession
}

/// Production ``WebSocketSessionFactory`` backed by `URLSession`.
public struct URLSessionWebSocketFactory: WebSocketSessionFactory {
    let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        URLSessionWebSocket(task: urlSession.webSocketTask(with: request))
    }
}

/// Thin ``WebSocketSession`` wrapper over `URLSessionWebSocketTask`.
///
/// Marked `@unchecked Sendable` because it only forwards to the underlying task, which
/// is itself safe to use concurrently.
final class URLSessionWebSocket: WebSocketSession, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func open() {
        task.resume()
    }

    func close(code: WebSocketCloseCode, reason: String?) {
        // Every current WebSocketCloseCode raw value is a valid URLSession close code;
        // if that invariant is ever broken, close without a status code (.invalid is
        // URLSession's "no close code") rather than crash mid-teardown.
        let nativeCode = URLSessionWebSocketTask.CloseCode(rawValue: code.rawValue) ?? .invalid
        let reasonData = reason.map { Data($0.utf8) }
        task.cancel(with: nativeCode, reason: reasonData)
    }

    func send(_ message: WebSocketMessage) async throws {
        try await task.send(message.nativeMessage)
    }

    func receive() async throws -> WebSocketMessage {
        try WebSocketMessage(await task.receive())
    }

    /// Bridges `sendPing(pongReceiveHandler:)`, which can call its handler more than once when
    /// the socket is cancelled or aborted; ``ResumeOnceGuard`` keeps the continuation to a single
    /// resume. Cancelling the caller does not cancel the ping — the connection abandons a ping it
    /// has stopped waiting for, and closing the socket makes URLSession fail the pending handler.
    func ping() async throws {
        let resumeGuard = ResumeOnceGuard()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            task.sendPing { error in
                guard resumeGuard.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension WebSocketMessage {
    /// The equivalent `URLSessionWebSocketTask.Message`.
    fileprivate var nativeMessage: URLSessionWebSocketTask.Message {
        switch self {
        case .string(let text): .string(text)
        case .data(let data): .data(data)
        }
    }

    /// Maps a received `URLSessionWebSocketTask.Message`, rejecting unknown frame kinds.
    fileprivate init(_ message: URLSessionWebSocketTask.Message) throws {
        switch message {
        case .string(let text): self = .string(text)
        case .data(let data): self = .data(data)
        @unknown default:
            throw RelayConnection.Error.unsupportedFrame
        }
    }
}
