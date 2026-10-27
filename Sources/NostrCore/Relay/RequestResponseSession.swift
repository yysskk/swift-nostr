import Foundation

/// A failure in the session machinery itself, which the owner maps into its own error type so callers
/// never see this one.
package enum RequestResponseSessionError: Error, Equatable, Sendable {
    /// No response arrived before the request's timeout elapsed.
    case timedOut

    /// The session was torn down — by ``RequestResponseSession/disconnect()``, or because the
    /// transport's event stream ended — while the request was waiting.
    case notConnected

    /// The task waiting for the response was cancelled. A request cancelled before it was sent is not
    /// sent at all; one cancelled afterwards may still be acted on by the peer.
    case cancelled

    /// The transport failed to connect, subscribe, or send.
    case transportFailed(RelayConnection.Error)

    /// A request was made under a key that already identifies one in flight.
    ///
    /// Correlation keys are expected to be unique — NIP-46 uses 16 random bytes, NIP-47 an event id
    /// whose content carries a random nonce — so this reports a defect in how they are generated
    /// rather than anything a relay or peer did.
    case duplicateRequestKey
}

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
/// - ``ensureStarted(subscriptionID:filters:handler:onEnded:)``, from every entry point, to connect
///   lazily, and to learn when the session ends on its own so it can finish whatever streams it
///   feeds from the handler.
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
///   was encrypted with, the parts collected so far), `Response` is what the caller awaits, and
///   `Failure` is the owner's error type, the only one the session throws.
package actor RequestResponseSession<
    Key: Hashable & Sendable, State: Sendable, Response: Sendable, Failure: Error
> {
    /// Receives every event the transport delivers, in arrival order.
    package typealias EventHandler = @Sendable (Event) async -> Void

    /// Runs once when a session ends because the transport's event stream did, rather than through
    /// ``disconnect()``.
    package typealias EndHandler = @Sendable () async -> Void

    /// Derives the response a timed-out request resolves with, from the state it accumulated.
    package typealias PartialResult = @Sendable (State) -> Response

    private let transport: any RelayTransport
    private let mapError: @Sendable (RequestResponseSessionError) -> Failure

    private var startTask: Task<Result<Void, RelayConnection.Error>, Never>?
    private var readerTask: Task<Void, Never>?
    /// The owner's ``EndHandler`` running for a session whose event stream ended.
    ///
    /// A new session waits for it before starting, so the owner finishes the old session's streams
    /// before anything can be registered against the new one — otherwise a stream opened on the
    /// fresh session could be finished by the late notice about the previous one.
    private var endNotification: Task<Void, Never>?

    /// Identifies the current session, incremented on every start and on `disconnect()`.
    ///
    /// A reader loop outlives the stream it drains: `disconnect()` finishes the stream
    /// synchronously, but the loop only wakes up afterwards. By then a new session may already be
    /// running, and without this the stale loop's completion would retire it — clearing a healthy
    /// `readerTask`/`startTask` and failing requests that session had legitimately in flight — or,
    /// with none running, report a teardown the owner asked for as the stream ending on its own.
    private var sessionGeneration: UInt64 = 0

    /// In-flight requests, keyed by whatever correlates a response back to its request.
    private var pending: [Key: PendingRequest] = [:]

    /// Creates a session over `transport`.
    /// - Parameters:
    ///   - transport: The relay transport to drive.
    ///   - mapError: Converts each failure of the session's own into the owner's error type, so
    ///     callers keep seeing their module's error type rather than a shared one.
    package init(
        transport: any RelayTransport,
        mapError: @escaping @Sendable (RequestResponseSessionError) -> Failure
    ) {
        self.transport = transport
        self.mapError = mapError
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
    ///
    /// When the transport's event stream ends — automatic reconnection gave up, or the connections
    /// went away — the session fails its in-flight requests, calls `onEnded`, and the next call here
    /// starts it again. `onEnded` is not called for ``disconnect()``, whose caller already knows.
    /// - Throws: ``RequestResponseSessionError/transportFailed(_:)``, mapped, when the transport cannot
    ///   connect or subscribe.
    package func ensureStarted(
        subscriptionID: String,
        filters: [Filter],
        handler: @escaping EventHandler,
        onEnded: @escaping EndHandler
    ) async throws(Failure) {
        // Let the owner finish the previous session's streams first. Re-checked after each wait,
        // since another session may have started and ended while this call was suspended.
        while let endNotification {
            await endNotification.value
            if self.endNotification == endNotification {
                self.endNotification = nil
            }
        }
        if let startTask {
            if case .failure(let error) = await startTask.value {
                throw mapError(.transportFailed(error))
            }
            return
        }
        // Claimed here rather than inside `performStart`: that runs in a task that must first hop
        // onto the actor, and a previous session's reader waking during that hop would still match
        // the old generation — retiring the session being built by clearing the very `startTask`
        // assigned just below.
        sessionGeneration &+= 1
        let generation = sessionGeneration

        let task = Task { [weak self] () -> Result<Void, RelayConnection.Error> in
            guard let self else { return .success(()) }
            do throws(RelayConnection.Error) {
                try await self.performStart(
                    subscriptionID: subscriptionID, filters: filters, handler: handler, onEnded: onEnded,
                    generation: generation)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        startTask = task
        if case .failure(let error) = await task.value {
            // Clear on failure so a later attempt can retry the setup.
            startTask = nil
            throw mapError(.transportFailed(error))
        }
    }

    private func performStart(
        subscriptionID: String,
        filters: [Filter],
        handler: @escaping EventHandler,
        onEnded: @escaping EndHandler,
        generation: UInt64
    ) async throws(RelayConnection.Error) {
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
            await self?.handleEventStreamEnded(generation: generation, onEnded: onEnded)
        }
    }

    /// Retires a session whose event stream has ended, failing anything in flight, clearing the
    /// started state so the next request reconnects rather than sending into a transport that can
    /// no longer answer, and telling the owner through `onEnded`.
    ///
    /// Ignored when `generation` is no longer current: the loop reporting the end belongs to a
    /// session that has already been replaced or disconnected, and the owner has nothing to learn.
    private func handleEventStreamEnded(generation: UInt64, onEnded: @escaping EndHandler) {
        guard generation == sessionGeneration else { return }
        readerTask = nil
        startTask = nil

        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.yield(.failure(mapError(.notConnected)))
            request.continuation.finish()
        }
        pending.removeAll()

        // Run outside this actor's turn: the owner hops to its own isolation to finish its streams.
        endNotification = Task { await onEnded() }
    }

    /// Opens an additional subscription, or replaces one under an id already in use.
    /// - Throws: ``RequestResponseSessionError/transportFailed(_:)``, mapped, when the transport
    ///   cannot subscribe.
    package func subscribe(id: String, filters: [Filter]) async throws(Failure) {
        do throws(RelayConnection.Error) {
            try await transport.subscribe(id: id, filters: filters)
        } catch {
            throw mapError(.transportFailed(error))
        }
    }

    /// Closes the subscription with `id`.
    package func unsubscribe(id: String) async {
        await transport.unsubscribe(id: id)
    }

    /// Stops reading, fails every in-flight request with ``RequestResponseSessionError/notConnected``, and
    /// disconnects the transport. A later ``ensureStarted(subscriptionID:filters:handler:onEnded:)``
    /// starts the session again.
    ///
    /// The owner's `onEnded` is not called: it asked for the teardown, and finishes its own streams.
    package func disconnect() async {
        // Retire the generation so the cancelled reader's end is not reported as the stream ending.
        sessionGeneration &+= 1
        readerTask?.cancel()
        readerTask = nil
        startTask?.cancel()
        startTask = nil

        for request in pending.values {
            request.timeoutTask?.cancel()
            request.continuation.yield(.failure(mapError(.notConnected)))
            request.continuation.finish()
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
    ///   - state: The owner's per-request state, which its handler folds responses into through
    ///     ``withPendingRequest(_:_:)``.
    ///   - timeout: How long to wait before the request fails (or resolves, see `partialResult`).
    ///   - partialResult: When non-`nil`, a timeout resolves the waiter with what the request has
    ///     collected so far instead of failing it — NIP-47's `multi_pay_*` returns the responses
    ///     that did arrive.
    /// - Returns: The response the owner resolved the request with, as
    ///   ``RequestResolution/resolved(_:)``.
    /// - Throws: The error the owner failed the request with through ``RequestResolution/failed(_:)``,
    ///   or, mapped: ``RequestResponseSessionError/timedOut`` if no response arrives in time,
    ///   ``RequestResponseSessionError/notConnected`` if the session ends first,
    ///   ``RequestResponseSessionError/cancelled`` if the calling task is cancelled,
    ///   ``RequestResponseSessionError/transportFailed(_:)`` if the send fails, or
    ///   ``RequestResponseSessionError/duplicateRequestKey`` when `key` is already in flight.
    package func perform(
        _ event: Event,
        key: Key,
        state: State,
        timeout: Duration,
        partialResult: PartialResult? = nil
    ) async throws(Failure) -> Response {
        // Overwriting an entry would drop the first request's continuation without resolving it and
        // leave its timeout running: that caller would stay suspended forever — its own cleanup
        // never runs, because it never returns — while the orphaned timeout resolved this request
        // on the first one's schedule. The newcomer is refused instead, since it has not sent
        // anything yet and the request already in flight may be about to be answered.
        guard pending[key] == nil else {
            throw mapError(.duplicateRequestKey)
        }
        // Once sent, a request may be acted on whether or not anyone still waits for the answer, so
        // a caller that has already gone away sends nothing.
        guard !Task.isCancelled else {
            throw mapError(.cancelled)
        }

        let (stream, continuation) = AsyncStream<Result<Response, Failure>>.makeStream()
        // Scheduling the timeout as part of the registration is safe: its task cannot re-enter the
        // actor until this call suspends, by which point the entry it looks for exists.
        pending[key] = PendingRequest(
            state: state,
            continuation: continuation,
            timeoutTask: makeTimeoutTask(key: key, timeout: timeout),
            partialResult: partialResult)
        defer { discard(key) }

        do throws(RelayConnection.Error) {
            try await transport.send(event)
        } catch {
            throw mapError(.transportFailed(error))
        }

        // Every resolution yields a result, so the stream ends without one only when the waiting
        // task is cancelled.
        for await result in stream {
            return try result.get()
        }
        throw mapError(.cancelled)
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
        _ body: @Sendable (inout State) -> RequestResolution<Response, Failure>
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
            request.continuation.yield(.success(response))
            request.continuation.finish()
        case .failed(let error):
            pending.removeValue(forKey: key)
            request.timeoutTask?.cancel()
            request.continuation.yield(.failure(error))
            request.continuation.finish()
        }
        return request.state
    }

    /// A task that resolves the request under `key` once `timeout` has elapsed.
    private func makeTimeoutTask(key: Key, timeout: Duration) -> Task<Void, Never> {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.timeOut(key)
        }
    }

    private func timeOut(_ key: Key) {
        guard let request = pending.removeValue(forKey: key) else { return }
        if let partialResult = request.partialResult {
            request.continuation.yield(.success(partialResult(request.state)))
        } else {
            request.continuation.yield(.failure(mapError(.timedOut)))
        }
        request.continuation.finish()
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
        let continuation: AsyncStream<Result<Response, Failure>>.Continuation
        /// The task that resolves the request on timeout; replaced when the handler returns
        /// ``RequestResolution/pendingFor(_:)``, and cancelled once the request resolves.
        var timeoutTask: Task<Void, Never>?
        /// When non-`nil`, a timeout resolves the waiter with this instead of failing it.
        let partialResult: PartialResult?
    }
}

/// What a decoded response means for the request it belongs to — the verdict
/// ``RequestResponseSession/withPendingRequest(_:_:)`` acts on.
package enum RequestResolution<Response: Sendable, Failure: Error>: Sendable {
    /// Keep the request pending, retaining whatever the handler wrote to its state: NIP-47
    /// collecting one part of a `multi_pay_*` reply that is still incomplete.
    case pending

    /// Keep it pending and restart its timeout to run for this long from now: NIP-46
    /// extending a request that drew an `auth_url` challenge, to give the user time to authorize.
    case pendingFor(Duration)

    /// Resolve the waiter with this response.
    case resolved(Response)

    /// Fail the waiter with this error.
    case failed(Failure)
}
