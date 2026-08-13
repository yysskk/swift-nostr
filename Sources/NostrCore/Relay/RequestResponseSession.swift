import Foundation

/// The request/response machinery a NIP-46 remote-signer session and a NIP-47 wallet connection
/// share, on top of a ``RelayTransport``.
///
/// Both protocols run the same loop: connect once, subscribe for the peer's events, read them on a
/// single task, register a waiter per outgoing request, and resolve it when the matching response
/// arrives — or fail it when the timeout elapses. Only the correlation differs: NIP-46 keys a
/// request by the `id` inside its encrypted JSON body, NIP-47 by the request event's id, which the
/// response echoes in its `e` tag. This type is therefore generic over the key and leaves every
/// protocol-specific decision — encryption, decoding, and when a request is complete — to its owner.
///
/// The owner drives it from three places:
/// - ``ensureStarted(subscriptionID:filters:handler:)``, from every entry point, to connect lazily.
/// - ``perform(_:key:state:timeout:partialResult:)``, to send a request and await its response.
/// - ``withPendingRequest(_:_:)``, from the handler, to fold each decoded response into the request
///   it belongs to.
///
/// Folding happens in one closure on this actor, so reading a request's state, updating it, and
/// deciding whether that completes the request is a single atomic step: the request's timeout
/// cannot fire partway through and drop a response the owner has already decoded.
///
/// - Note: `Sendable` payloads only: `Key` correlates a response to its request, `State` is
///   whatever the owner needs to interpret that response (the method a request used, the scheme it
///   was encrypted with, the parts collected so far), and `Response` is what the caller awaits.
package actor RequestResponseSession<Key: Hashable & Sendable, State: Sendable, Response: Sendable> {
    /// Receives every event the transport delivers, in arrival order.
    package typealias EventHandler = @Sendable (Event) async -> Void

    /// Derives the response a timed-out request resolves with, from the state it accumulated.
    package typealias PartialResult = @Sendable (State) -> Response

    private let transport: any RelayTransport
    private let timedOut: any Error
    private let notConnected: any Error

    private var startTask: Task<Void, any Error>?
    private var readerTask: Task<Void, Never>?

    /// Identifies the current session, incremented on every start.
    ///
    /// A reader loop outlives the stream it drains: `disconnect()` finishes the stream
    /// synchronously, but the loop only wakes up afterwards. By then a new session may already be
    /// running, and without this the stale loop's completion would retire it — clearing a healthy
    /// `readerTask`/`startTask` and failing requests that session had legitimately in flight.
    private var sessionGeneration: UInt64 = 0

    /// In-flight requests, keyed by whatever correlates a response back to its request.
    private var pending: [Key: PendingRequest] = [:]

    /// Creates a session over `transport`.
    /// - Parameters:
    ///   - transport: The relay transport to drive.
    ///   - timedOut: The error a request fails with when its timeout elapses.
    ///   - notConnected: The error in-flight requests fail with when ``disconnect()`` tears the
    ///     session down. Both are supplied by the owner so callers keep seeing their module's error
    ///     type rather than a shared one.
    package init(transport: any RelayTransport, timedOut: any Error, notConnected: any Error) {
        self.transport = transport
        self.timedOut = timedOut
        self.notConnected = notConnected
    }

    /// Whether the session has been started and not since disconnected.
    package var isStarted: Bool {
        startTask != nil
    }

    // MARK: - Lifecycle

    /// Connects the transport, opens the response subscription, and starts delivering events to
    /// `handler` — once per session.
    ///
    /// The setup is tracked as a shared task so a concurrent caller on first use awaits the same
    /// connect/subscribe work, rather than racing past a bool guard and sending before the transport
    /// is connected and the subscription exists. Later callers await that same task and their
    /// arguments are ignored; a failed attempt is discarded so the next call retries the setup.
    package func ensureStarted(
        subscriptionID: String,
        filters: [Filter],
        handler: @escaping EventHandler
    ) async throws {
        if let startTask {
            try await startTask.value
            return
        }
        // Claimed here rather than inside `performStart`: that runs in a task that must first hop
        // onto the actor, and a previous session's reader waking during that hop would still match
        // the old generation — retiring the session being built by clearing the very `startTask`
        // assigned just below.
        sessionGeneration &+= 1
        let generation = sessionGeneration

        let task = Task { [weak self] in
            guard let self else { return }
            try await self.performStart(
                subscriptionID: subscriptionID, filters: filters, handler: handler,
                generation: generation)
        }
        startTask = task
        do {
            try await task.value
        } catch {
            // Clear on failure so a later attempt can retry the setup.
            startTask = nil
            throw error
        }
    }

    private func performStart(
        subscriptionID: String,
        filters: [Filter],
        handler: @escaping EventHandler,
        generation: UInt64
    ) async throws {
        try await transport.connect()
        // Subscribe before sending anything so a response delivered during the subscribe
        // round-trip is not missed.
        try await transport.subscribe(id: subscriptionID, filters: filters)

        let events = await transport.events()
        readerTask = Task { [weak self] in
            for await event in events {
                await handler(event)
            }
            // The merged stream ends when every relay's has — auto-reconnect gave up, or the
            // connections were torn down. Nothing will deliver a response after this, so the
            // session has to notice: left as it was, `isStarted` stayed true, `ensureStarted`
            // short-circuited, and every later request sent into a dead transport and waited out
            // its whole timeout with no error explaining why.
            await self?.handleEventStreamEnded(generation: generation)
        }
    }

    /// Retires a session whose event stream has ended, failing anything in flight and clearing the
    /// started state so the next request reconnects rather than sending into a transport that can
    /// no longer answer.
    ///
    /// Ignored when `generation` is no longer current: the loop reporting the end belongs to a
    /// session that has already been replaced, and the one running now is healthy.
    private func handleEventStreamEnded(generation: UInt64) {
        guard generation == sessionGeneration else { return }
        readerTask = nil
        startTask = nil

        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: notConnected)
        }
        pending.removeAll()
    }

    /// Opens an additional subscription, or replaces one under an id already in use.
    package func subscribe(id: String, filters: [Filter]) async throws {
        try await transport.subscribe(id: id, filters: filters)
    }

    /// Closes the subscription with `id`.
    package func unsubscribe(id: String) async {
        await transport.unsubscribe(id: id)
    }

    /// Stops reading, fails every in-flight request with the session's `notConnected` error, and
    /// disconnects the transport. A later ``ensureStarted(subscriptionID:filters:handler:)`` starts
    /// the session again.
    package func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        startTask?.cancel()
        startTask = nil

        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: notConnected)
        }
        pending.removeAll()

        await transport.disconnect()
    }

    // MARK: - Requests

    /// Registers a waiter under `key`, sends `event`, and awaits the response.
    ///
    /// The waiter is registered before the send so a response that arrives during the send
    /// round-trip is not lost, and is deregistered on every exit path — including a throwing send.
    /// - Parameters:
    ///   - event: The request event to publish.
    ///   - key: What the response will be correlated by.
    ///   - state: The owner's per-request state, readable from its handler through ``state(for:)``.
    ///   - timeout: How long to wait before the request fails (or resolves, see `partialResult`).
    ///   - partialResult: When non-`nil`, a timeout resolves the waiter with what the request has
    ///     collected so far instead of failing it — NIP-47's `multi_pay_*` returns the responses
    ///     that did arrive.
    /// - Returns: The response the owner delivered with ``complete(_:with:)``.
    /// - Throws: The session's `timedOut` error if no response arrives in time, the error passed to
    ///   ``fail(_:with:)``, or a transport error from the send.
    package func perform(
        _ event: Event,
        key: Key,
        state: State,
        timeout: TimeInterval,
        partialResult: PartialResult? = nil
    ) async throws -> Response {
        let (stream, continuation) = AsyncThrowingStream<Response, any Error>.makeStream()
        // Scheduling the timeout as part of the registration is safe: its task cannot re-enter the
        // actor until this call suspends, by which point the entry it looks for exists.
        pending[key] = PendingRequest(
            state: state,
            continuation: continuation,
            timeoutTask: makeTimeoutTask(key: key, timeout: timeout),
            partialResult: partialResult)
        defer { discard(key) }

        try await transport.send(event)

        for try await response in stream {
            return response
        }
        throw timedOut
    }

    /// Folds a decoded response into the in-flight request under `key`.
    ///
    /// `body` runs synchronously on this actor, so it sees the request's state, updates it, and
    /// says what that means for the waiter without anything interleaving — in particular the
    /// request cannot time out between the read and the update.
    /// - Parameters:
    ///   - key: The key the response correlates to.
    ///   - body: Folds the response into the request's state and returns the resulting
    ///     ``RequestResolution``.
    /// - Returns: The request's state after `body` ran, or `nil` when nothing was pending under
    ///   `key` — an unknown, duplicate, or already-resolved response.
    @discardableResult
    package func withPendingRequest(
        _ key: Key,
        _ body: @Sendable (inout State) -> RequestResolution<Response>
    ) -> State? {
        guard var request = pending[key] else { return nil }

        switch body(&request.state) {
        case .pending:
            pending[key] = request
        case .pendingFor(let timeout):
            request.timeoutTask?.cancel()
            request.timeoutTask = makeTimeoutTask(key: key, timeout: timeout)
            pending[key] = request
        case .resolved(let response):
            pending.removeValue(forKey: key)
            request.timeoutTask?.cancel()
            request.continuation.yield(response)
            request.continuation.finish()
        case .failed(let error):
            pending.removeValue(forKey: key)
            request.timeoutTask?.cancel()
            request.continuation.finish(throwing: error)
        }
        return request.state
    }

    /// A task that resolves the request under `key` once `timeout` seconds have elapsed.
    private func makeTimeoutTask(key: Key, timeout: TimeInterval) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.timeOut(key)
        }
    }

    private func timeOut(_ key: Key) {
        guard let request = pending.removeValue(forKey: key) else { return }
        if let partialResult = request.partialResult {
            request.continuation.yield(partialResult(request.state))
            request.continuation.finish()
        } else {
            request.continuation.finish(throwing: timedOut)
        }
    }

    /// Deregisters the request under `key` and cancels its timeout without resolving its waiter —
    /// the waiter has already been resolved, or its caller is leaving.
    private func discard(_ key: Key) {
        guard let request = pending.removeValue(forKey: key) else { return }
        request.timeoutTask?.cancel()
    }

    /// State for one in-flight request awaiting its response.
    private struct PendingRequest {
        /// The owner's per-request state, read back by its handler when a response arrives.
        var state: State
        let continuation: AsyncThrowingStream<Response, any Error>.Continuation
        /// The task that resolves the request on timeout; replaced by ``extendTimeout(for:to:)``,
        /// and cancelled once the request resolves.
        var timeoutTask: Task<Void, Never>?
        /// When non-`nil`, a timeout resolves the waiter with this instead of failing it.
        let partialResult: PartialResult?
    }
}

/// What a decoded response means for the request it belongs to — the verdict
/// ``RequestResponseSession/withPendingRequest(_:_:)`` acts on.
package enum RequestResolution<Response: Sendable>: Sendable {
    /// Keep the request pending, retaining whatever the handler wrote to its state: NIP-47
    /// collecting one part of a `multi_pay_*` reply that is still incomplete.
    case pending

    /// Keep it pending and restart its timeout to run for this many seconds from now: NIP-46
    /// extending a request that drew an `auth_url` challenge, to give the user time to authorize.
    case pendingFor(TimeInterval)

    /// Resolve the waiter with this response.
    case resolved(Response)

    /// Fail the waiter with this error.
    case failed(any Error)
}
