import Foundation
// Non-@testable import: ``RequestResponseSession`` is package-visible, and the suite drives it the
// way a NIP-46 signer session or a NIP-47 wallet connection does.
import NostrCore
import Testing

/// Exercises the session machinery both NIP-46 and NIP-47 run on: starting once, correlating a
/// response back to its request, timing out (or resolving with what arrived), and tearing down.
///
/// The correlation itself is the owner's job, so these tests stand in for one: the handler reads the
/// key off the event's `e` tag and resolves the request through the session, exactly as a real owner
/// does after decrypting.
@Suite("RequestResponseSession Tests")
struct RequestResponseSessionTests {
    /// Keys are strings; a request accumulates the response parts it has seen.
    private typealias Session = RequestResponseSession<String, [String], [String]>

    private enum TestError: Error, Equatable {
        case timedOut
        case notConnected
        case connectFailed
        case rejected
    }

    private static let subscriptionID = "test-responses"

    private func makeSession(_ transport: FakeTransport) -> Session {
        Session(transport: transport, timedOut: TestError.timedOut, notConnected: TestError.notConnected)
    }

    /// Starts `session`, resolving each incoming event's request — keyed by its `e` tag — with the
    /// event's content.
    private func start(_ session: Session) async throws {
        try await session.ensureStarted(subscriptionID: Self.subscriptionID, filters: [Filter(kinds: [1])]) {
            [weak session] event in
            guard let session, let key = event.firstTagValue(named: "e") else { return }
            await session.complete(key, with: [event.content])
        }
    }

    private func request(_ id: String) -> Event {
        Event(id: id, pubkey: "client", createdAt: 0, kind: 1, tags: [], content: "", sig: "")
    }

    private func response(for key: String, content: String) -> Event {
        Event(id: "resp-\(key)", pubkey: "peer", createdAt: 0, kind: 1, tags: [["e", key]], content: content, sig: "")
    }

    // MARK: - Lifecycle

    @Test("the first request connects, subscribes, then sends — in that order")
    func startsBeforeSending() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        async let response = session.perform(request("a"), key: "a", state: [], timeout: 1)
        try await transport.waitForSends(1)
        await transport.deliver(self.response(for: "a", content: "ok"))
        #expect(try await response == ["ok"])

        #expect(await transport.log == [.connect, .subscribe(Self.subscriptionID), .send("a")])
    }

    @Test("concurrent callers share one start and none sends before the subscription exists")
    func concurrentCallersShareOneStart() async throws {
        let transport = FakeTransport()
        await transport.closeGate()
        let session = makeSession(transport)

        // Both callers arrive while the transport is still connecting.
        async let first: [String] = perform(session, transport: transport, key: "a")
        async let second: [String] = perform(session, transport: transport, key: "b")
        try await transport.waitForConnectAttempts(1)
        // Hold the gate a moment longer: a caller that raced past the setup would send here, and the
        // log below would show it. A caller that waits for the shared setup cannot.
        try await Task.sleep(for: .milliseconds(50))
        await transport.openGate()

        #expect(try await first == ["a-done"])
        #expect(try await second == ["b-done"])

        // One connect and one subscribe, and neither send raced ahead of the subscription.
        #expect(await transport.connectCount == 1)
        let log = await transport.log
        #expect(log.prefix(2) == [.connect, .subscribe(Self.subscriptionID)])
        #expect(log.filter { $0 == .subscribe(Self.subscriptionID) }.count == 1)
    }

    @Test("a failed start is retried by the next caller")
    func failedStartIsRetried() async throws {
        let transport = FakeTransport()
        await transport.failNextConnect(with: TestError.connectFailed)
        let session = makeSession(transport)

        await #expect(throws: TestError.connectFailed) {
            try await self.start(session)
        }

        try await start(session)
        #expect(await transport.connectCount == 2)
        #expect(await transport.isConnected == true)
    }

    @Test("disconnect fails in-flight requests with notConnected and disconnects the transport")
    func disconnectFailsPending() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task { try await session.perform(self.request("a"), key: "a", state: [], timeout: 5) }
        try await transport.waitForSends(1)
        await session.disconnect()

        await #expect(throws: TestError.notConnected) { try await pending.value }
        #expect(await transport.isConnected == false)
        #expect(await session.isStarted == false)
    }

    // MARK: - Correlation

    @Test("concurrent requests resolve with their own responses, whatever the arrival order")
    func concurrentRequestsCorrelateByKey() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        async let first = session.perform(request("a"), key: "a", state: [], timeout: 1)
        async let second = session.perform(request("b"), key: "b", state: [], timeout: 1)
        try await transport.waitForSends(2)

        await transport.deliver(response(for: "b", content: "second"))
        await transport.deliver(response(for: "a", content: "first"))

        #expect(try await first == ["first"])
        #expect(try await second == ["second"])
    }

    @Test("a response for an unknown key is ignored and the request still times out")
    func unknownKeyIgnored() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task { try await session.perform(self.request("a"), key: "a", state: [], timeout: 0.3) }
        try await transport.waitForSends(1)
        await transport.deliver(response(for: "unknown", content: "stray"))

        await #expect(throws: TestError.timedOut) { try await pending.value }
    }

    @Test("state registered with a request is readable and replaceable while it is in flight")
    func stateRoundTrips() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task { try await session.perform(self.request("a"), key: "a", state: ["one"], timeout: 1) }
        try await transport.waitForSends(1)

        #expect(await session.state(for: "a") == ["one"])
        await session.update(["one", "two"], for: "a")
        #expect(await session.state(for: "a") == ["one", "two"])

        await session.complete("a", with: await session.state(for: "a") ?? [])
        #expect(try await pending.value == ["one", "two"])
        // Resolved requests are deregistered, so their state is gone.
        #expect(await session.state(for: "a") == nil)
    }

    @Test("fail surfaces the given error to the waiter")
    func failSurfacesError() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task { try await session.perform(self.request("a"), key: "a", state: [], timeout: 5) }
        try await transport.waitForSends(1)
        await session.fail("a", with: TestError.rejected)

        await #expect(throws: TestError.rejected) { try await pending.value }
    }

    // MARK: - Timeouts

    @Test("a request with no response fails with the session's timedOut error")
    func requestTimesOut() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        await #expect(throws: TestError.timedOut) {
            _ = try await session.perform(self.request("a"), key: "a", state: [], timeout: 0.2)
        }
    }

    @Test("a timed-out request resolves with its partial result when one is supplied")
    func timeoutResolvesWithPartialResult() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task {
            try await session.perform(
                self.request("a"), key: "a", state: [], timeout: 0.3, partialResult: { $0 })
        }
        try await transport.waitForSends(1)
        // One part arrives before the deadline; the request resolves with it instead of failing.
        await session.update(["arrived"], for: "a")

        #expect(try await pending.value == ["arrived"])
    }

    @Test("extendTimeout keeps a request pending past its original deadline")
    func extendedTimeoutOutlivesTheOriginal() async throws {
        let transport = FakeTransport()
        let session = makeSession(transport)
        try await start(session)

        let pending = Task { try await session.perform(self.request("a"), key: "a", state: [], timeout: 0.2) }
        try await transport.waitForSends(1)
        await session.extendTimeout(for: "a", to: 5)

        // Wait out the original timeout, then answer: the request is still waiting.
        try await Task.sleep(for: .milliseconds(400))
        await transport.deliver(response(for: "a", content: "late"))
        #expect(try await pending.value == ["late"])
    }

    // MARK: - Helpers

    /// Starts the session, sends the request under `key`, answers it, and returns what resolved.
    private func perform(_ session: Session, transport: FakeTransport, key: String) async throws -> [String] {
        try await start(session)
        async let response = session.perform(request(key), key: key, state: [], timeout: 2)
        try await transport.waitForSend(key)
        await transport.deliver(self.response(for: key, content: "\(key)-done"))
        return try await response
    }
}

/// An in-memory ``RelayTransport`` that records the order of the operations a session drives it
/// with, and can hold `connect()` open or fail it, so the start-once path can be exercised.
private actor FakeTransport: RelayTransport {
    enum Operation: Equatable {
        case connect
        case subscribe(String)
        case unsubscribe(String)
        case send(String)
    }

    private(set) var log: [Operation] = []
    private(set) var isConnected = false
    private(set) var connectCount = 0

    private var continuation: AsyncStream<Event>.Continuation?
    private var isGateOpen = true
    private var gate: CheckedContinuation<Void, Never>?
    private var nextConnectError: (any Error)?

    func connect() async throws {
        log.append(.connect)
        connectCount += 1
        if !isGateOpen {
            await withCheckedContinuation { gate = $0 }
        }
        if let error = nextConnectError {
            nextConnectError = nil
            throw error
        }
        isConnected = true
    }

    func subscribe(id: String, filters: [Filter]) async throws {
        log.append(.subscribe(id))
    }

    func unsubscribe(id: String) async {
        log.append(.unsubscribe(id))
    }

    func send(_ event: Event) async throws {
        log.append(.send(event.id))
    }

    func events() -> AsyncStream<Event> {
        continuation?.finish()
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        self.continuation = continuation
        return stream
    }

    func disconnect() async {
        isConnected = false
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Test controls

    /// Pushes a simulated incoming event to the ``events()`` stream.
    func deliver(_ event: Event) {
        continuation?.yield(event)
    }

    /// Holds the next `connect()` open until ``openGate()``.
    func closeGate() {
        isGateOpen = false
    }

    func openGate() {
        isGateOpen = true
        gate?.resume()
        gate = nil
    }

    /// Fails the next `connect()` with `error`, once.
    func failNextConnect(with error: any Error) {
        nextConnectError = error
    }

    /// Polls until at least `count` events have been sent.
    func waitForSends(_ count: Int) async throws {
        try await poll { self.log.filter { if case .send = $0 { return true } else { return false } }.count >= count }
    }

    /// Polls until the event with `id` has been sent.
    func waitForSend(_ id: String) async throws {
        try await poll { self.log.contains(.send(id)) }
    }

    /// Polls until `connect()` has been entered at least `count` times.
    func waitForConnectAttempts(_ count: Int) async throws {
        try await poll { self.connectCount >= count }
    }

    private func poll(until condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw PollTimeout()
    }
}

/// Thrown when one of ``FakeTransport``'s wait helpers gives up, failing the test that called it.
private struct PollTimeout: Error {}
