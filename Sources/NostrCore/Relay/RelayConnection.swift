import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Manages a WebSocket connection to a single Nostr relay
public actor RelayConnection {
    /// Produces a signed kind-22242 event answering an AUTH challenge, or
    /// `nil` to leave the challenge unanswered (NIP-42).
    public typealias AuthenticationResponder = @Sendable (_ relayURL: RelayURL, _ challenge: String) async -> Event?

    /// The relay URL.
    ///
    /// `nonisolated` because it is an immutable `Sendable` value fixed at init:
    /// callers (e.g. the relay pool, now in a separate module) read it
    /// synchronously without hopping onto the actor.
    public nonisolated let url: RelayURL

    /// Current connection state
    public private(set) var state: RelayConnectionState = .disconnected

    // The actor's behavior is organized across focused extension files
    // (RelayConnection+Receiving / +Keepalive / +Reconnection). Stored state those
    // extensions touch is `internal` rather than `private`; state used only in this
    // file stays `private`. All access remains actor-isolated either way.

    /// Active subscriptions (subscription ID -> filters) for resubscription after reconnect
    var subscriptions: [SubscriptionID: [Filter]] = [:]

    /// REQs still on their way out, by subscription ID: the send's token and the filters the ID
    /// was registered with before it. A failed REQ restores them only while its token is still
    /// here — a later subscribe, unsubscribe, or teardown on the ID replaces or removes the entry.
    private var subscriptionRequestsInFlight: [SubscriptionID: (token: UInt64, previousFilters: [Filter]?)] = [:]

    /// The token of the most recent REQ sent.
    private var lastSubscriptionRequestToken: UInt64 = 0

    /// The active WebSocket transport
    var webSocketTask: (any WebSocketSession)?

    /// Identifies the socket currently in ``webSocketTask``, incremented on every install.
    ///
    /// Everything that outlives a socket — the connect attempt waiting on its ping, the receive
    /// loop, the keepalive, an in-flight send — captures this value and compares it before touching
    /// shared state. Without it, work belonging to a socket that has since been replaced or torn
    /// down lands on whatever session is current: an attempt could report `.connected` for a socket
    /// `disconnect()` had already discarded, leaving the connection wedged in a state that reports
    /// healthy while nothing is listening and no reconnect is pending.
    private var socketGeneration: UInt64 = 0

    /// Creates the WebSocket transport for each connection attempt
    private let webSocketFactory: any WebSocketSessionFactory

    /// Connection configuration
    public let config: RelayConnectionConfig

    /// Current reconnection attempt count
    var reconnectAttempts: Int = 0

    /// Current reconnect delay
    var currentReconnectDelay: Duration = .seconds(1)

    /// Draws the random factor each reconnect delay is scaled by. Injectable so tests can pin it.
    var jitter: ReconnectJitter = { range in Double.random(in: range) }

    /// Whether reconnection is in progress
    var isReconnecting: Bool = false

    /// Reconnection task
    var reconnectTask: Task<Void, Never>?

    /// Keepalive ping task; non-nil only while the connection is believed healthy
    var keepaliveTask: Task<Void, Never>?

    /// Receive loop for the current socket. Held so teardown can cancel it: the loop otherwise
    /// stays parked in `receive()` keeping the connection alive through its own capture of `self`.
    var receiveTask: Task<Void, Never>?

    /// In-flight connection attempt, shared by concurrent connect() callers. The attempt's outcome
    /// is carried as a `Result` so every sharer receives the typed ``Error``.
    private var connectTask: Task<Result<Void, Error>, Never>?

    /// Identifies the in-flight connect attempt, so a finishing attempt only clears
    /// ``connectTask`` if it is still the one stored there.
    private var connectAttempt: UInt64 = 0

    /// Continuations for async message receiving (supports multiple consumers)
    var messageContinuations: [UUID: AsyncStream<RelayMessage>.Continuation] = [:]

    /// Continuation for connection state changes
    private var stateChangeContinuations: [UUID: AsyncStream<RelayConnectionState>.Continuation] = [:]

    /// Pending continuations waiting for OK response after publish,
    /// keyed by event id and then by a per-publish token so concurrent
    /// publishes of the same event don't clobber each other's waiters
    private var pendingPublishWaiters: [EventID: [UUID: AsyncThrowingStream<Void, any Swift.Error>.Continuation]] = [:]

    /// Continuations waiting for a NIP-45 COUNT response, keyed by the generated
    /// COUNT subscription id. One waiter per subid: the ids are unique per
    /// request, so a reply correlates to exactly one in-flight ``countEvents(matching:timeout:)``.
    /// `internal` (not `private`) because the receive loop in `+Receiving` settles them.
    var pendingCountWaiters: [SubscriptionID: AsyncThrowingStream<EventCount, any Swift.Error>.Continuation] = [:]

    /// The most recent challenge received in an AUTH message from the relay (NIP-42).
    ///
    /// `nil` until the relay sends a challenge; replaced when the relay sends a
    /// newer one. A challenge is only valid for the WebSocket session that
    /// delivered it, so it is cleared whenever the connection is torn down or
    /// re-established.
    public internal(set) var authenticationChallenge: String?

    /// The public keys this connection has successfully authenticated (NIP-42).
    ///
    /// A public key is added when the relay acknowledges its AUTH event with OK
    /// `true`. Authentication only lasts for the current WebSocket session, so
    /// the set is emptied whenever the connection is torn down or re-established.
    /// Multiple public keys can be authenticated on one connection by calling
    /// ``authenticate(with:)`` once per identity.
    public private(set) var authenticatedPublicKeys: Set<PublicKey> = []

    /// The error from the most recent automatic NIP-42 authentication attempt driven
    /// by the ``AuthenticationResponder``, or nil when none has failed.
    ///
    /// Usually a ``RelayConnection/Error`` — ``RelayConnection/Error/authenticationRejected(_:)``
    /// when the relay refused the AUTH event — but any failure of the attempt is recorded, so
    /// it is never silently lost.
    ///
    /// Cleared when an authentication later succeeds and whenever the session is torn
    /// down or re-established (challenges are per-session). A responder that returns
    /// nil declines the challenge and is not recorded as an error. Manual
    /// ``authenticate(with:)`` callers observe failures as thrown errors instead and
    /// are not recorded here.
    public private(set) var lastAuthenticationError: (any Swift.Error)?

    /// Public keys of in-flight AUTH events keyed by event id, so the receive loop
    /// can mark them authenticated the moment the relay's OK arrives. An entry
    /// lives only as long as its ``authenticate(with:)`` call: a failed or
    /// cancelled call removes it, so a late OK after a reported failure cannot
    /// silently flip the connection to authenticated.
    var pendingAuthentications: [EventID: PublicKey] = [:]

    /// Answers AUTH challenges automatically when set (NIP-42). Configuration
    /// rather than session state: it survives reconnects, so challenges the
    /// relay issues on a fresh session are answered too.
    var authenticationResponder: AuthenticationResponder?

    /// Whether a responder-driven answer is currently in flight, from invoking
    /// the responder until its AUTH round-trip settles. Cleared by the
    /// answering task itself, so it cannot get stuck by a session reset.
    private var isAnsweringChallenge = false

    /// Subscriptions the relay closed with `auth-required:`, re-requested
    /// automatically after the next successful authentication (NIP-42).
    var subscriptionsAwaitingAuthentication: Set<SubscriptionID> = []

    /// Continuations suspended in ``waitForAuthentication()``, settled by the
    /// receive loop when an AUTH round-trip concludes.
    private var authenticationWaiters: [UUID: AsyncThrowingStream<Void, any Swift.Error>.Continuation] = [:]

    /// Whether at least one public key is authenticated on this connection (NIP-42).
    public var isAuthenticated: Bool {
        !authenticatedPublicKeys.isEmpty
    }

    /// The number of callers currently parked in ``waitForAuthentication()`` (for tests).
    var authenticationWaiterCount: Int {
        authenticationWaiters.count
    }

    /// Whether an authentication outcome is plausibly imminent: one already
    /// succeeded, one is in flight, or a responder is installed to answer the
    /// challenges the relay sends.
    private var canExpectAuthentication: Bool {
        isAuthenticated || !pendingAuthentications.isEmpty || authenticationResponder != nil
    }

    /// Creates a connection to `url`.
    ///
    /// By default the sockets come from a `URLSession`-backed ``URLSessionWebSocketFactory`` over
    /// `URLSession.shared`; pass `URLSessionWebSocketFactory(urlSession:)` to use another session.
    /// Supply a custom ``WebSocketSessionFactory`` to run the connection on a platform-native
    /// socket — for example an OkHttp-backed factory on Android, whose Foundation has no working
    /// WebSocket support — or on an in-memory fake in tests. The whole
    /// connect/receive/keepalive/reconnect state machine then runs on that transport.
    /// - Parameters:
    ///   - url: The relay's URL.
    ///   - config: Timeout, keepalive, and reconnection behavior (defaults to `.default`).
    ///   - webSocketFactory: Creates the transport for each connection attempt (defaults to a
    ///     ``URLSessionWebSocketFactory`` over `URLSession.shared`).
    public init(
        url: RelayURL,
        config: RelayConnectionConfig = .default,
        webSocketFactory: any WebSocketSessionFactory = URLSessionWebSocketFactory()
    ) {
        self.url = url
        self.webSocketFactory = webSocketFactory
        self.config = config
        self.currentReconnectDelay = config.firstReconnectDelay
    }

    /// Creates a connection whose reconnect delays are randomized by `jitter` instead of the
    /// system generator, so a test can assert the backoff bounds without depending on chance.
    init(
        url: RelayURL,
        config: RelayConnectionConfig,
        webSocketFactory: any WebSocketSessionFactory,
        jitter: @escaping ReconnectJitter
    ) {
        self.url = url
        self.webSocketFactory = webSocketFactory
        self.config = config
        self.currentReconnectDelay = config.firstReconnectDelay
        self.jitter = jitter
    }

    /// Connects to the relay.
    ///
    /// Concurrent callers share a single in-flight attempt: a caller arriving while
    /// another task is still connecting awaits that attempt's real outcome instead
    /// of returning early with the socket not yet established. Every sharer sees
    /// the same success or failure.
    ///
    /// - Throws: ``RelayConnection/Error/connectionFailed`` when the socket cannot be opened or
    ///   does not answer the verifying ping within ``RelayConnectionConfig/connectionTimeout``, or
    ///   ``RelayConnection/Error/notConnected`` when ``disconnect()`` or a newer attempt discards
    ///   the socket before the attempt completes.
    public func connect() async throws(Error) {
        if state == .connected { return }

        if let existing = connectTask {
            try await existing.value.get()
            return
        }

        guard
            state == .disconnected
                || {
                    if case .failed = state { return true }
                    return false
                }()
        else { return }

        // Unstructured on purpose: one caller's cancellation must not abort the
        // attempt other callers are waiting on. The slot is cleared inside the
        // task itself so it lives exactly as long as the attempt — clearing it
        // from the caller would be tied to the caller's lifetime instead.
        connectAttempt &+= 1
        let attempt = connectAttempt
        let task = Task { () -> Result<Void, Error> in
            // Only clear the slot if it still holds this attempt: a `disconnect()` during the
            // attempt may already have replaced or cleared it.
            defer { if connectAttempt == attempt { connectTask = nil } }
            do throws(Error) {
                try await performConnect()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        connectTask = task
        try await task.value.get()
    }

    /// Installs `socket` as the live transport, returning the generation that identifies it.
    ///
    /// Any socket already installed is cancelled rather than dropped: overwriting it would leave a
    /// live connection nobody closes, and its receive loop would keep running against a relay that
    /// still believes the session is open.
    private func installSocket(_ socket: any WebSocketSession) -> UInt64 {
        webSocketTask?.close(code: .abnormalClosure, reason: nil)
        socketGeneration &+= 1
        webSocketTask = socket
        return socketGeneration
    }

    /// Whether `generation` still identifies the installed socket.
    func isCurrentSocket(_ generation: UInt64) -> Bool {
        socketGeneration == generation
    }

    /// Establishes the WebSocket connection and verifies it with a ping.
    private func performConnect() async throws(Error) {
        updateState(.connecting)

        // NIP-42 challenges and authentications are scoped to a WebSocket
        // session; a fresh socket starts unauthenticated with no challenge.
        resetAuthenticationState()

        var request = URLRequest(url: url.url)
        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.timeoutInterval = config.connectionTimeout.timeInterval

        let task = webSocketFactory.makeWebSocket(with: request)
        let generation = installSocket(task)
        task.open()

        // Verify connection with ping before marking as connected (with timeout)
        do {
            try await Self.pingSocket(task, timeout: config.connectionTimeout)

            // The ping suspended this attempt, and a `disconnect()` or a later attempt may have
            // discarded the socket meanwhile. Reporting `.connected` for it now would describe a
            // session that no longer exists — and, since `connect()` returns early while the state
            // says connected, nothing would ever repair it.
            guard isCurrentSocket(generation) else {
                throw Error.notConnected
            }

            updateState(.connected)
            resetReconnectState()
            startReceiving(generation: generation)
            startKeepalive(generation: generation)
        } catch {
            // A superseded attempt reports its own failure without touching the session that
            // replaced it.
            guard isCurrentSocket(generation) else {
                throw .notConnected
            }
            updateState(.failed(error.localizedDescription))
            discardSocket()
            throw .connectionFailed
        }
    }

    /// Cancels and clears the installed socket, retiring its generation so anything still holding
    /// the old one stops short instead of acting on the next session.
    func discardSocket() {
        webSocketTask?.close(code: .abnormalClosure, reason: nil)
        webSocketTask = nil
        socketGeneration &+= 1
    }

    /// Disconnects from the relay.
    ///
    /// The teardown is the same from every state, including
    /// ``RelayConnectionState/failed(_:)`` — the state a connection sits in after any dropped
    /// connection. Callers waiting on a publish or a count are failed with
    /// ``RelayConnection/Error/notConnected`` rather than left to their timeouts, tracked
    /// subscriptions are dropped so a later ``connect()`` does not replay them, and NIP-42 session
    /// state is cleared.
    ///
    /// Terminal for ``messages()`` streams: every open stream finishes so
    /// `for await` consumers end. A stream taken after this point belongs to the next session and
    /// stays open until it arrives. ``stateChanges()`` streams stay open — they
    /// observe the transition to ``RelayConnectionState/disconnected`` and any
    /// later ``connect()``.
    public func disconnect() {
        // Cancel any pending reconnection
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        keepaliveTask?.cancel()
        keepaliveTask = nil
        // The receive loop holds `self` while parked in receive(), so leaving it running keeps the
        // whole connection — socket included — alive after the last reference is gone.
        receiveTask?.cancel()
        receiveTask = nil
        // An attempt still waiting on its ping must not resume into `.connected` after this.
        connectTask?.cancel()
        connectTask = nil

        // Terminal for message streams regardless of the current state: a
        // consumer's `for await` must end even when the receive loop already
        // exited with a reconnect pending, or when the connection was never
        // established at all.
        finishMessageStreams()

        // `.disconnecting` describes closing a live socket, so it is only announced when there is
        // one. Everything below runs from every state: a connection that dropped sits in `.failed`,
        // and skipping the teardown there left publish callers waiting out the full ack timeout,
        // subscriptions ready to be replayed on the next connect, and `isAuthenticated` reporting
        // true for a session that no longer existed.
        let wasLive = state == .connected || state == .connecting
        if wasLive {
            updateState(.disconnecting)
            webSocketTask?.close(code: .normalClosure, reason: nil)
            webSocketTask = nil
            socketGeneration &+= 1
        } else {
            // Retire the socket's generation on this path too, so an attempt suspended in its ping
            // cannot resume and install itself over a connection that was torn down.
            discardSocket()
        }

        subscriptions.removeAll()
        subscriptionRequestsInFlight.removeAll()
        for waiters in pendingPublishWaiters.values {
            for waiter in waiters.values {
                waiter.finish(throwing: Error.notConnected)
            }
        }
        pendingPublishWaiters.removeAll()
        for waiter in pendingCountWaiters.values {
            waiter.finish(throwing: Error.notConnected)
        }
        pendingCountWaiters.removeAll()
        resetAuthenticationState()

        // Announcing `.disconnected` again for a connection already in that state would report a
        // transition that did not happen to every `stateChanges()` consumer.
        if state != .disconnected {
            updateState(.disconnected)
        }
    }

    /// Clears all NIP-42 session state. Challenges, authenticated public keys, and
    /// auth-pending subscriptions are only valid for a single WebSocket
    /// session, so this runs on every teardown and before every (re)connection
    /// attempt. Waiters blocked on an authentication are failed: their session
    /// is gone, and any re-authentication belongs to the next one.
    private func resetAuthenticationState() {
        authenticationChallenge = nil
        authenticatedPublicKeys.removeAll()
        lastAuthenticationError = nil
        pendingAuthentications.removeAll()
        subscriptionsAwaitingAuthentication.removeAll()
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()
        for waiter in waiters {
            waiter.finish(throwing: Error.notConnected)
        }
    }

    /// Applies the outcome of an AUTH round-trip observed by the receive loop:
    /// a success records the public key, wakes ``waitForAuthentication()`` callers,
    /// and re-requests subscriptions the relay closed with `auth-required:`; a
    /// rejection fails the waiters with ``RelayConnection/Error/authenticationRejected(_:)``.
    func settleAuthentication(publicKey: PublicKey, accepted: Bool, message: String) {
        let waiters = authenticationWaiters.values
        authenticationWaiters.removeAll()

        guard accepted else {
            let error = Error.authenticationRejected(RelayRejection(status: message))
            for waiter in waiters {
                waiter.finish(throwing: error)
            }
            return
        }

        authenticatedPublicKeys.insert(publicKey)
        lastAuthenticationError = nil
        for waiter in waiters {
            waiter.finish()
        }
        resubscribeAfterAuthentication()
    }

    /// Re-requests the subscriptions the relay closed with `auth-required:`.
    /// Unstructured because it runs from the receive loop, which must not
    /// block on the REQ sends; subscriptions unsubscribed in the meantime are
    /// skipped.
    private func resubscribeAfterAuthentication() {
        let awaiting = subscriptionsAwaitingAuthentication
        subscriptionsAwaitingAuthentication.removeAll()
        guard !awaiting.isEmpty else { return }

        Task {
            for subscriptionID in awaiting {
                guard let filters = subscriptions[subscriptionID] else { continue }
                try? await subscribe(id: subscriptionID, filters: filters)
            }
        }
    }

    /// Sends a client message to the relay.
    ///
    /// Fails fast with ``RelayConnection/Error/notConnected`` when the connection is not established —
    /// like ``publish(_:)``, a send never connects inline. Call ``connect()`` first; reconnection
    /// after a drop is owned by the background auto-reconnect.
    ///
    /// Cancelling the calling task does not interrupt the send: the frame is still written, and
    /// the call returns or throws as it would have — only a socket failure or the send timeout
    /// fails the connection. A cancelled caller learns of it at its next cancellation check.
    ///
    /// - Throws: ``RelayConnection/Error/notConnected`` when the connection is not established or
    ///   the socket fails the send, the error ``ClientMessage/serialize()`` throws, or
    ///   ``RelayConnection/Error/timedOut`` when the send does not complete within
    ///   ``RelayConnectionConfig/sendTimeout``.
    public func send(_ message: ClientMessage) async throws {
        guard state == .connected, let task = webSocketTask else {
            throw Error.notConnected
        }
        let generation = socketGeneration

        let text = message.serialize()

        // Track subscription state before the frame goes out: the send suspends, and an
        // unsubscribe arriving meanwhile must find the subscription to forget and CLOSE — tracked
        // only afterwards, the REQ would register a subscription its caller already ended. A
        // `.count` message is intentionally not tracked: it is a one-shot request that must never
        // be replayed on reconnect.
        var request: (subscriptionID: SubscriptionID, token: UInt64)?
        switch message {
        case .request(let subscriptionID, let filters):
            lastSubscriptionRequestToken &+= 1
            request = (subscriptionID, lastSubscriptionRequestToken)
            subscriptionRequestsInFlight[subscriptionID] = (
                lastSubscriptionRequestToken, subscriptions[subscriptionID]
            )
            subscriptions[subscriptionID] = filters
        case .close(let subscriptionID):
            forgetSubscription(subscriptionID)
        default:
            break
        }

        // The write runs in a task of its own so the caller's cancellation does not reach it: a
        // cancelled child would end the race at once, and the connection would be failed and torn
        // down over a socket that is healthy — just because one caller went away.
        let sendTimeout = config.sendTimeout
        let write = Task {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await task.send(.string(text))
                }

                group.addTask {
                    try await Task.sleep(for: sendTimeout)
                    throw Error.timedOut
                }

                try await group.next()
                group.cancelAll()
            }
        }

        do {
            try await write.value
        } catch {
            // Update state on send failure, but only for the session this send belonged to: the
            // send timeout fires on a merely slow relay, and by the time it does the socket may
            // already have been replaced. The socket is discarded rather than left installed —
            // otherwise the next connect would overwrite a live connection nobody closes, and its
            // receive loop would go on running beside the new one.
            if isCurrentSocket(generation) {
                updateState(.failed(error.localizedDescription))
                discardSocket()
                scheduleReconnectIfNeeded()
            }
            if let request {
                finishSubscriptionRequest(request, succeeded: false)
            }
            if let error = error as? Error {
                throw error
            } else {
                throw Error.notConnected
            }
        }

        if let request {
            finishSubscriptionRequest(request, succeeded: true)
        }
    }

    /// Settles the REQ sent under `request`. A failed one puts back the filters its subscription ID
    /// had before — none for a new subscription — unless the ID changed hands while it was in
    /// flight: a newer subscribe's registration is not clobbered, and one an unsubscribe removed is
    /// not resurrected.
    private func finishSubscriptionRequest(_ request: (subscriptionID: SubscriptionID, token: UInt64), succeeded: Bool)
    {
        guard let inFlight = subscriptionRequestsInFlight[request.subscriptionID],
            inFlight.token == request.token
        else { return }
        subscriptionRequestsInFlight.removeValue(forKey: request.subscriptionID)
        guard !succeeded else { return }
        subscriptions[request.subscriptionID] = inFlight.previousFilters
    }

    /// Forgets a subscription, including any REQ for it still in flight, so neither a reconnection
    /// nor a failing REQ brings it back.
    private func forgetSubscription(_ subscriptionID: SubscriptionID) {
        subscriptions.removeValue(forKey: subscriptionID)
        subscriptionRequestsInFlight.removeValue(forKey: subscriptionID)
    }

    /// Publishes an event to the relay and waits for OK from the relay.
    ///
    /// Fails fast with ``RelayConnection/Error/notConnected`` when the connection is not established —
    /// the publish path never connects inline, so a dead relay fails immediately instead of
    /// spending up to `connectionTimeout` on a reconnect attempt. Reconnection is owned by
    /// the background auto-reconnect with exponential backoff.
    ///
    /// When the relay rejects the event with `auth-required:` and this
    /// connection can authenticate (NIP-42) — an ``AuthenticationResponder`` is
    /// installed, an AUTH round-trip is in flight, or one already succeeded —
    /// the publish waits for the authentication to conclude and retries once.
    ///
    /// When the NIP-42 retry path is active and the relay rejects the AUTH event itself, the
    /// publish throws ``RelayConnection/Error/authenticationRejected(_:)`` — the root cause —
    /// instead of the auth-required rejection.
    ///
    /// - Throws: ``RelayRejection`` when the relay answers OK `false` (branch on its
    ///   ``RelayRejection/prefix``), ``RelayConnection/Error/notConnected`` when the connection is
    ///   not established or is torn down while waiting, ``RelayConnection/Error/timedOut`` when no
    ///   OK arrives within ``RelayConnectionConfig/publishAckTimeout``,
    ///   ``RelayConnection/Error/authenticationRejected(_:)`` as above, or what ``send(_:)`` throws.
    public func publish(_ event: Event) async throws {
        guard state == .connected else {
            throw Error.notConnected
        }

        do {
            try await sendAndAwaitOK(.event(event), eventID: event.id)
        } catch let rejection as RelayRejection {
            try await retryPublishAfterAuthentication(event, rejection: rejection)
        }
    }

    /// Handles a publish rejection, retrying once after authentication for an
    /// `auth-required:` rejection that authentication can plausibly cure
    /// (NIP-42). Relays send the AUTH challenge right before or after such a
    /// rejection, so waiting for the (typically automatic) AUTH round-trip and
    /// resending delivers the event without the caller doing anything.
    ///
    /// Any other rejection — including a second one from the retry — surfaces
    /// as the ``RelayRejection`` itself.
    private func retryPublishAfterAuthentication(_ event: Event, rejection: RelayRejection) async throws {
        guard rejection.prefix == .authRequired, canExpectAuthentication else {
            throw rejection
        }

        do {
            try await waitForAuthentication()
        } catch Error.timedOut {
            // Authentication never concluded, so the original rejection stands.
            throw rejection
        }

        try await sendAndAwaitOK(.event(event), eventID: event.id)
    }

    /// Suspends until an AUTH round-trip on this connection succeeds, bounded
    /// by ``RelayConnectionConfig/publishAckTimeout``. Returns immediately when
    /// already authenticated.
    ///
    /// This is the middle leg of the auth-retry publish path, which makes a
    /// publish take up to 3× the ack timeout end to end: the rejected attempt,
    /// this wait, and the retried attempt each get the full bound.
    ///
    /// - Throws: ``RelayConnection/Error/authenticationRejected(_:)`` when the relay
    ///   rejects the AUTH event, ``RelayConnection/Error/timedOut`` when no round-trip
    ///   concludes in time, ``RelayConnection/Error/notConnected`` when the session is torn down.
    private func waitForAuthentication() async throws {
        if isAuthenticated { return }

        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, any Swift.Error>.makeStream()
        authenticationWaiters[token] = continuation

        defer {
            authenticationWaiters.removeValue(forKey: token)?.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in stream {
                    return
                }
            }

            group.addTask {
                try await Task.sleep(for: self.config.publishAckTimeout)
                throw Error.timedOut
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// Authenticates this connection with a pre-signed kind-22242 event and
    /// waits for the relay's OK (NIP-42).
    ///
    /// Most callers should prefer ``authenticate(using:)``, which builds and
    /// signs the event from the stored ``authenticationChallenge``. Use this
    /// overload when the event is produced elsewhere.
    ///
    /// On success the event's public key is added to ``authenticatedPublicKeys`` and
    /// the relay treats it as authenticated for the rest of the session.
    ///
    /// - Parameter event: A signed ``Event/Kind/clientAuthentication`` event
    ///   carrying `relay` and `challenge` tags.
    /// - Throws: ``RelayConnection/Error/invalidAuthenticationEventKind(_:)`` when the event is
    ///   not kind 22242, ``RelayConnection/Error/authenticationRejected(_:)`` when the relay
    ///   answers OK `false`, ``RelayConnection/Error/notConnected`` when the connection is not
    ///   established or is torn down while waiting, ``RelayConnection/Error/timedOut`` when no
    ///   OK arrives within ``RelayConnectionConfig/publishAckTimeout``, or what ``send(_:)`` throws.
    public func authenticate(with event: Event) async throws {
        guard event.kind == .clientAuthentication else {
            throw Error.invalidAuthenticationEventKind(event.kind)
        }
        guard state == .connected else {
            throw Error.notConnected
        }

        // Recorded before sending so the receive loop can mark the public key as
        // authenticated the moment the OK arrives while this call is in flight.
        pendingAuthentications[event.id] = event.publicKey

        do {
            try await sendAndAwaitOK(.auth(event), eventID: event.id)
        } catch let rejection as RelayRejection {
            throw Error.authenticationRejected(rejection)
        } catch {
            // Once a failure (timeout, send error, cancellation) is reported to
            // the caller, a late OK must not silently flip the connection to
            // authenticated — drop the pending entry along with the error.
            pendingAuthentications.removeValue(forKey: event.id)
            throw error
        }
    }

    /// Builds, signs, and sends the answer to the relay's most recent AUTH
    /// challenge, then waits for the relay's OK (NIP-42).
    ///
    /// - Parameter signer: The signer for the identity to authenticate, local or remote.
    /// - Throws: ``RelayConnection/Error/missingAuthenticationChallenge`` when the relay has not
    ///   sent a challenge yet, anything the signer throws, plus everything
    ///   ``authenticate(with:)`` throws.
    public func authenticate(using signer: some NostrSigning) async throws {
        guard let challenge = authenticationChallenge else {
            throw Error.missingAuthenticationChallenge
        }
        let event = try await signer.sign(.clientAuthentication(relayURL: url, challenge: challenge))
        try await authenticate(with: event)
    }

    /// Sets or clears the responder that answers AUTH challenges automatically (NIP-42).
    ///
    /// While a responder is set, every challenge the relay sends — including on
    /// later sessions after a reconnect — is passed to it, and a returned event
    /// is sent back through ``authenticate(with:)``. A challenge that is already
    /// stored and still unanswered is answered immediately, so installing a
    /// responder after the relay has demanded authentication needs no extra step.
    ///
    /// Automatic authentication is best-effort: outcomes are observable through
    /// ``authenticatedPublicKeys``, ``lastAuthenticationError``, and the relay's OK
    /// in ``messages()``, and a failed attempt is not retried until the relay
    /// issues another challenge.
    public func setAuthenticationResponder(_ responder: AuthenticationResponder?) {
        authenticationResponder = responder
        guard let responder,
            let challenge = authenticationChallenge,
            shouldAnswerChallenge
        else { return }
        respondToChallenge(challenge, with: responder)
    }

    /// Whether a challenge should be answered now.
    ///
    /// An answer already under way, or an authentication already established for this session,
    /// makes another redundant. It is also unsafe: ``isAnsweringChallenge`` is a single flag that
    /// whichever answer finishes first clears, so overlapping answers leave it reading `false`
    /// while one is still running.
    var shouldAnswerChallenge: Bool {
        !isAuthenticated && !isAnsweringChallenge && pendingAuthentications.isEmpty
    }

    /// Asks `responder` to answer `challenge` and authenticates with the result.
    /// Unstructured so the caller — typically the receive loop — never blocks
    /// on signing or on the AUTH round-trip.
    ///
    /// ``isAnsweringChallenge`` covers the whole task, including the responder
    /// call that precedes the ``pendingAuthentications`` registration, so
    /// installing a responder mid-answer cannot start a second answer for the
    /// same challenge.
    func respondToChallenge(_ challenge: String, with responder: @escaping AuthenticationResponder) {
        isAnsweringChallenge = true
        Task {
            defer { isAnsweringChallenge = false }
            guard let event = await responder(url, challenge) else { return }
            do {
                try await authenticate(with: event)
            } catch {
                // Only record the failure while still on the same challenge. If the
                // session was torn down (``resetAuthenticationState()`` cleared the
                // challenge) or the relay issued a new one while this attempt was
                // suspended, a late failure must not resurrect a stale error — the
                // field is scoped to the current session.
                guard authenticationChallenge == challenge else { return }
                lastAuthenticationError = error
            }
        }
    }

    /// Sends `message` and suspends until the relay's OK for `eventID` arrives,
    /// bounded by ``RelayConnectionConfig/publishAckTimeout``. Shared by
    /// ``publish(_:)`` and ``authenticate(with:)``.
    ///
    /// - Throws: ``RelayRejection`` when the relay answers OK `false`,
    ///   ``RelayConnection/Error/timedOut`` when no OK arrives in time.
    private func sendAndAwaitOK(_ message: ClientMessage, eventID: EventID) async throws {
        let token = UUID()
        let (stream, continuation) = AsyncThrowingStream<Void, any Swift.Error>.makeStream()
        pendingPublishWaiters[eventID, default: [:]][token] = continuation

        do {
            try await send(message)
        } catch {
            removePublishWaiter(eventID: eventID, token: token)?.finish()
            throw error
        }

        defer {
            removePublishWaiter(eventID: eventID, token: token)?.finish()
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await _ in stream {
                    return
                }
            }

            group.addTask {
                try await Task.sleep(for: self.config.publishAckTimeout)
                throw Error.timedOut
            }

            try await group.next()
            group.cancelAll()
        }
    }

    /// Removes and returns a single publish waiter (called from within the actor).
    @discardableResult
    private func removePublishWaiter(
        eventID: EventID,
        token: UUID
    ) -> AsyncThrowingStream<Void, any Swift.Error>.Continuation? {
        guard var waiters = pendingPublishWaiters[eventID] else { return nil }
        let continuation = waiters.removeValue(forKey: token)
        if waiters.isEmpty {
            pendingPublishWaiters.removeValue(forKey: eventID)
        } else {
            pendingPublishWaiters[eventID] = waiters
        }
        return continuation
    }

    /// Removes and returns all publish waiters for an event id —
    /// one OK from the relay satisfies every pending publish of that event.
    func removeAllPublishWaiters(eventID: EventID) -> [AsyncThrowingStream<Void, any Swift.Error>.Continuation] {
        guard let waiters = pendingPublishWaiters.removeValue(forKey: eventID) else { return [] }
        return Array(waiters.values)
    }

    /// Requests the number of events matching `filters` (NIP-45 COUNT) and waits for
    /// the relay's response.
    ///
    /// Relays that do not implement NIP-45 usually never reply; the call then fails with
    /// ``RelayConnection/Error/timedOut`` after `timeout`. A CLOSED for the COUNT subscription
    /// fails fast with a ``RelayRejection``.
    /// - Parameters:
    ///   - filters: The filters whose matching events to count.
    ///   - timeout: How long to wait for the relay to answer; `nil` uses
    ///     ``RelayConnectionConfig/queryTimeout``.
    /// - Throws: ``RelayRejection`` when the relay answers CLOSED,
    ///   ``RelayConnection/Error/timedOut`` when no answer arrives within `timeout`,
    ///   ``RelayConnection/Error/notConnected`` when not connected or torn down while waiting, or
    ///   what ``send(_:)`` throws.
    /// https://github.com/nostr-protocol/nips/blob/master/45.md
    public func countEvents(matching filters: [Filter], timeout: Duration? = nil) async throws -> EventCount {
        guard state == .connected else {
            throw Error.notConnected
        }

        let timeout = timeout ?? config.queryTimeout
        let subscriptionID = SubscriptionID.random()
        let (stream, continuation) = AsyncThrowingStream<EventCount, any Swift.Error>.makeStream()
        pendingCountWaiters[subscriptionID] = continuation

        do {
            try await send(.count(subscriptionID: subscriptionID, filters: filters))
        } catch {
            pendingCountWaiters.removeValue(forKey: subscriptionID)?.finish()
            throw error
        }

        defer {
            pendingCountWaiters.removeValue(forKey: subscriptionID)?.finish()
        }

        return try await withThrowingTaskGroup(of: EventCount.self) { group in
            group.addTask {
                for try await count in stream {
                    return count
                }
                throw Error.notConnected
            }

            group.addTask {
                try await Task.sleep(for: timeout)
                throw Error.timedOut
            }

            guard let result = try await group.next() else {
                throw Error.notConnected
            }
            group.cancelAll()
            return result
        }
    }

    /// Subscribes to events matching the given filters, connecting first when the connection is not
    /// established.
    ///
    /// The subscription is re-requested after every automatic reconnection until
    /// ``unsubscribe(id:)`` or ``disconnect()``.
    ///
    /// - Throws: Everything ``connect()`` throws, or what ``send(_:)`` throws.
    public func subscribe(id subscriptionID: SubscriptionID, filters: [Filter]) async throws {
        if state != .connected {
            try await connect()
        }
        try await send(.request(subscriptionID: subscriptionID, filters: filters))
    }

    /// Unsubscribes from a subscription.
    ///
    /// The subscription is forgotten at once — even while its REQ is still being sent — so a
    /// reconnection does not re-request it. A CLOSE goes
    /// out only when the connection is established and holds the subscription; otherwise this does
    /// nothing, and it never connects — a dropped socket took the relay's subscription with it. A
    /// CLOSE that fails to send is not reported: the failure discards the socket, and the relay's
    /// subscription with it. Like every ``send(_:)``, the CLOSE goes out even when the calling task
    /// is cancelled.
    public func unsubscribe(id subscriptionID: SubscriptionID) async {
        guard subscriptions[subscriptionID] != nil else { return }
        forgetSubscription(subscriptionID)
        guard state == .connected else { return }
        try? await send(.close(subscriptionID: subscriptionID))
    }

    /// Returns an async stream of messages from this relay.
    /// Each call creates a new stream that receives all future messages.
    ///
    /// A stream is bound to the connection, not to one socket: it survives automatic reconnections
    /// and keeps delivering from the new session. Taking a stream before connecting is the normal
    /// way to use it — register first, then ``connect()`` and ``subscribe(id:filters:)``
    /// — so a stream taken while disconnected stays open and begins delivering when the next
    /// session arrives, rather than finishing on the spot.
    ///
    /// It finishes when the connection is torn down for good: on ``disconnect()``, when
    /// auto-reconnect gives up after ``ReconnectPolicy/maximumAttempts`` failed attempts, or when
    /// the connection drops with ``RelayConnectionConfig/reconnect`` set to `nil`. With the default
    /// configuration (unlimited reconnect attempts) only an explicit ``disconnect()`` finishes it.
    /// Streams open at that point end; a stream taken afterwards belongs to the next session, so
    /// call ``messages()`` again after reconnecting manually.
    public func messages() -> AsyncStream<RelayMessage> {
        let id = UUID()
        return AsyncStream { continuation in
            self.messageContinuations[id] = continuation
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeMessageContinuation(id: id)
                }
            }
        }
    }

    /// Returns an async stream of connection state changes.
    ///
    /// Unlike ``messages()`` streams, state streams are not finished by
    /// ``disconnect()``: they yield the final `.disconnected` and remain open
    /// to observe a later ``connect()``. A stream ends when its consumer stops
    /// iterating.
    public func stateChanges() -> AsyncStream<RelayConnectionState> {
        let id = UUID()
        return AsyncStream { continuation in
            self.stateChangeContinuations[id] = continuation
            // Emit current state immediately
            continuation.yield(self.state)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { [weak self] in
                    await self?.removeStateContinuation(id: id)
                }
            }
        }
    }

    /// Removes a message continuation by ID
    private func removeMessageContinuation(id: UUID) {
        messageContinuations.removeValue(forKey: id)
    }

    /// Finishes and removes every active ``messages()`` stream.
    ///
    /// Called on terminal teardown — an explicit ``disconnect()``, automatic
    /// reconnection giving up, or the receive loop exiting with no reconnect
    /// pending — so `for await` consumers end instead of waiting forever.
    /// Idempotent: finishing an already-finished continuation is a no-op. The
    /// dictionary is emptied before finishing so the `onTermination` cleanup
    /// tasks the finishes trigger find nothing left to remove.
    func finishMessageStreams() {
        let continuations = messageContinuations.values
        messageContinuations.removeAll()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Removes a state continuation by ID
    private func removeStateContinuation(id: UUID) {
        stateChangeContinuations.removeValue(forKey: id)
    }

    /// Updates state and notifies listeners
    func updateState(_ newState: RelayConnectionState) {
        state = newState
        for continuation in stateChangeContinuations.values {
            continuation.yield(newState)
        }
    }

    /// Checks if a subscription is active
    public func hasSubscription(_ subscriptionID: SubscriptionID) -> Bool {
        subscriptions[subscriptionID] != nil
    }

    /// Returns all active subscription IDs
    public func activeSubscriptions() -> Set<SubscriptionID> {
        Set(subscriptions.keys)
    }

}

// MARK: - Equatable
extension RelayConnection: Equatable {
    public static func == (lhs: RelayConnection, rhs: RelayConnection) -> Bool {
        lhs.url == rhs.url
    }
}

// MARK: - Hashable
extension RelayConnection: Hashable {
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
    }
}

// MARK: - NIP-11
extension RelayConnection {
    /// Fetches the NIP-11 Relay Information Document for this relay.
    ///
    /// This performs an HTTP GET request to the relay's URL (with the scheme
    /// converted from `wss://`/`ws://` to `https://`/`http://`) and works
    /// independently of the WebSocket connection state.
    ///
    /// - Parameter urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The decoded ``RelayInformation``.
    /// - Throws: ``RelayInformation/FetchError`` on network or decoding errors.
    public nonisolated func fetchInformation(urlSession: URLSession = .shared) async throws -> RelayInformation {
        try await RelayInformation.fetch(from: url, urlSession: urlSession)
    }
}

// MARK: - Error
extension RelayConnection {
    /// Why an operation on a ``RelayConnection`` failed.
    ///
    /// A relay that answers a request with OK `false` or CLOSED throws a ``RelayRejection``
    /// instead, except for a rejected AUTH event, which is ``authenticationRejected(_:)``.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The connection is not established, or was torn down while the operation waited.
        case notConnected
        /// The relay did not answer — a send, an OK, a COUNT, a ping, or an AUTH round-trip —
        /// within its configured timeout.
        case timedOut
        /// A connection attempt failed: the socket could not be opened or did not answer the
        /// verifying ping in time. ``RelayConnection/state`` describes the underlying failure.
        case connectionFailed
        /// The relay has not sent an AUTH challenge to answer (NIP-42).
        case missingAuthenticationChallenge
        /// The event passed to ``RelayConnection/authenticate(with:)`` is not a
        /// ``Event/Kind/clientAuthentication`` event (payload: the event's kind).
        case invalidAuthenticationEventKind(Event.Kind)
        /// The relay answered the AUTH event with OK `false` (payload: the relay's rejection).
        case authenticationRejected(RelayRejection)
        /// The WebSocket delivered a frame that is neither text nor binary.
        case unsupportedFrame

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to relay"
            case .timedOut:
                return "The relay did not answer in time"
            case .connectionFailed:
                return "Could not connect to the relay"
            case .missingAuthenticationChallenge:
                return "The relay has not sent an AUTH challenge"
            case .invalidAuthenticationEventKind(let kind):
                return
                    "An authentication event must be kind \(Event.Kind.clientAuthentication), got kind \(kind)"
            case .authenticationRejected(let rejection):
                return "The relay rejected the authentication event: \(rejection.status)"
            case .unsupportedFrame:
                return "The WebSocket delivered an unsupported frame"
            }
        }
    }
}
