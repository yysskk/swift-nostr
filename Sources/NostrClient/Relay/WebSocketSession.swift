import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A WebSocket transport used by ``RelayConnection``.
///
/// Abstracting the socket behind this protocol lets the connection's state machine —
/// connect, receive, keepalive, and reconnect — be driven by an in-memory fake in
/// tests, so the logic can be exercised without a live network relay. The production
/// transport is ``URLSessionWebSocket``, a thin wrapper over `URLSessionWebSocketTask`.
protocol WebSocketSession: Sendable {
    /// Begins the WebSocket handshake.
    func resume()

    /// Closes the socket with the given close code and optional reason.
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)

    /// Sends a single WebSocket frame.
    func send(_ message: URLSessionWebSocketTask.Message) async throws

    /// Receives the next WebSocket frame, suspending until one arrives or the socket fails.
    func receive() async throws -> URLSessionWebSocketTask.Message

    /// Sends a ping; `pongReceiveHandler` is invoked when the pong arrives or the ping fails.
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

/// Creates a ``WebSocketSession`` for a request.
///
/// Injected into ``RelayConnection`` so tests can supply a fake transport in place of
/// `URLSession`. The production implementation is ``URLSessionWebSocketFactory``.
protocol WebSocketSessionFactory: Sendable {
    /// Creates a new, unstarted transport for `request`.
    func makeWebSocket(with request: URLRequest) -> any WebSocketSession
}

/// Production ``WebSocketSessionFactory`` backed by `URLSession`.
struct URLSessionWebSocketFactory: WebSocketSessionFactory {
    let urlSession: URLSession

    func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
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

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        try await task.send(message)
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await task.receive()
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        task.sendPing(pongReceiveHandler: pongReceiveHandler)
    }
}
