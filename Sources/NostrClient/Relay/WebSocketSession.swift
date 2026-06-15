import Foundation
import NostrCore

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
/// integer codes, …) via ``RawRepresentable``.
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

/// A WebSocket transport used by ``RelayConnection``.
///
/// Abstracting the socket behind this protocol lets the connection's state machine —
/// connect, receive, keepalive, and reconnect — run on any transport:
///
/// - the default `URLSession`-backed ``URLSessionWebSocketFactory`` on Apple platforms,
/// - an in-memory fake in tests, so the logic can be exercised without a live relay, or
/// - a host-supplied native socket (for example OkHttp on Android) injected via
///   ``RelayPool/init(config:webSocketFactory:)`` or
///   ``NostrClient/init(relayPoolConfig:gossipPolicy:webSocketFactory:)``.
///
/// The protocol deliberately avoids `URLSessionWebSocketTask` types (``WebSocketMessage``
/// and ``WebSocketCloseCode`` stand in for them) so it compiles on platforms whose
/// Foundation lacks WebSocket support, such as Android.
public protocol WebSocketSession: Sendable {
    /// Begins the WebSocket handshake.
    func resume()

    /// Closes the socket with the given close code and optional reason.
    func cancel(with closeCode: WebSocketCloseCode, reason: Data?)

    /// Sends a single WebSocket frame.
    func send(_ message: WebSocketMessage) async throws

    /// Receives the next WebSocket frame, suspending until one arrives or the socket fails.
    func receive() async throws -> WebSocketMessage

    /// Sends a ping; `pongReceiveHandler` is invoked when the pong arrives or the ping fails.
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

/// Creates a ``WebSocketSession`` for a request.
///
/// Injected into ``RelayConnection``, ``RelayPool``, and ``NostrClient`` so a host can
/// supply a platform-native transport (or a test can supply a fake) in place of
/// `URLSession`. The default implementation is ``URLSessionWebSocketFactory``.
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

    func resume() {
        task.resume()
    }

    func cancel(with closeCode: WebSocketCloseCode, reason: Data?) {
        // Every WebSocketCloseCode raw value is a valid URLSession close code; fail
        // loudly rather than send a wrong code if that invariant is ever broken.
        guard let nativeCode = URLSessionWebSocketTask.CloseCode(rawValue: closeCode.rawValue) else {
            preconditionFailure("WebSocketCloseCode \(closeCode.rawValue) has no URLSession equivalent")
        }
        task.cancel(with: nativeCode, reason: reason)
    }

    func send(_ message: WebSocketMessage) async throws {
        try await task.send(message.nativeMessage)
    }

    func receive() async throws -> WebSocketMessage {
        try WebSocketMessage(await task.receive())
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
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
            throw NostrError.connectionFailed("Unsupported WebSocket frame")
        }
    }
}
