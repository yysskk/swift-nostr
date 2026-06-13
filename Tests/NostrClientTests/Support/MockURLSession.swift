import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// MARK: - URLProtocol Mock Infrastructure

/// A canned response served by ``MockURLProtocol`` for a single ``withMockURLSession(response:body:)`` call.
enum MockResponse {
    /// An HTTP response with the given status code and body.
    case success(status: Int, body: Data)

    /// A transport-level failure (e.g. `URLError(.cannotConnectToHost)`).
    case failure(Error)
}

/// The request captured by ``MockURLProtocol`` plus the value returned by the closure under test.
struct MockInvocation<Value> {
    let request: URLRequest?
    let returnValue: Value
}

/// Runs `body` with a `URLSession` backed by ``MockURLProtocol``, returning both the captured
/// `URLRequest` and the closure's return value.
///
/// The session intercepts every request and serves `response`, so tests exercise networking code
/// (status handling, decoding, cancellation) without making real network calls.
///
/// Mock sessions are serialized by ``MockURLSessionLock`` so only one is ever active at a time.
/// `URLProtocol` has no per-request routing hook that works on every platform — a session's
/// `httpAdditionalHeaders` are not delivered to `URLProtocol` on swift-corelibs-foundation (Linux) —
/// so routing concurrent sessions to their handlers is not portable. Serializing instead keeps
/// `MockURLProtocol`'s single active handler unambiguous on every platform. The network tests are
/// few and fast, so the lost parallelism is negligible.
@discardableResult
func withMockURLSession<Value>(
    response: MockResponse,
    body: (URLSession) async throws -> Value
) async throws -> MockInvocation<Value> {
    await MockURLSessionLock.shared.lock()
    do {
        let invocation = try await serveMockURLSession(response: response, body: body)
        await MockURLSessionLock.shared.unlock()
        return invocation
    } catch {
        await MockURLSessionLock.shared.unlock()
        throw error
    }
}

/// Registers `response`, runs `body` against a session wired to ``MockURLProtocol``, and returns the
/// captured request. Must be called while holding ``MockURLSessionLock`` so only one handler is active.
private func serveMockURLSession<Value>(
    response: MockResponse,
    body: (URLSession) async throws -> Value
) async throws -> MockInvocation<Value> {
    let handlerID = MockURLProtocol.register(response: response)
    defer { MockURLProtocol.unregister(handlerID: handlerID) }

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }

    let value = try await body(session)
    let captured = MockURLProtocol.capturedRequest(for: handlerID)
    return MockInvocation(request: captured, returnValue: value)
}

/// An async lock that serializes ``withMockURLSession(response:body:)`` calls so only one mock
/// session is active at a time (see that function for why routing concurrent sessions is not portable).
actor MockURLSessionLock {
    static let shared = MockURLSessionLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        guard isLocked else {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Thread-safe storage for the active ``MockURLProtocol`` handler and the request it captured.
final class MockURLProtocolRegistry: @unchecked Sendable {
    static let shared = MockURLProtocolRegistry()

    private let lock = NSLock()
    private var handlers: [UUID: MockResponse] = [:]
    private var captured: [UUID: URLRequest] = [:]
    private var currentID: UUID?

    func register(_ response: MockResponse) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let id = UUID()
        handlers[id] = response
        currentID = id
        return id
    }

    func unregister(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeValue(forKey: id)
        captured.removeValue(forKey: id)
        if currentID == id { currentID = nil }
    }

    func currentHandler() -> (UUID, MockResponse)? {
        lock.lock()
        defer { lock.unlock() }
        guard let id = currentID, let handler = handlers[id] else { return nil }
        return (id, handler)
    }

    func recordRequest(_ request: URLRequest, for id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        captured[id] = request
    }

    func capturedRequest(for id: UUID) -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return captured[id]
    }
}

/// A `URLProtocol` that serves the response registered by ``withMockURLSession(response:body:)`` and
/// records the request it received. Only one handler is active at a time (calls are serialized by
/// ``MockURLSessionLock``), so the active handler is looked up directly.
final class MockURLProtocol: URLProtocol {
    static func register(response: MockResponse) -> UUID {
        MockURLProtocolRegistry.shared.register(response)
    }

    static func unregister(handlerID: UUID) {
        MockURLProtocolRegistry.shared.unregister(handlerID)
    }

    static func capturedRequest(for handlerID: UUID) -> URLRequest? {
        MockURLProtocolRegistry.shared.capturedRequest(for: handlerID)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let (id, response) = MockURLProtocolRegistry.shared.currentHandler() else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        MockURLProtocolRegistry.shared.recordRequest(request, for: id)

        switch response {
        case .success(let status, let body):
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/nostr+json"]
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
