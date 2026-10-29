import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The default ``RelayTransport``, backed by one or more ``RelayConnection``s.
///
/// A session usually targets a single relay, but a connection URI may list several; this transport
/// connects to all of them, sends each request to all, and merges their incoming events into one
/// stream. Duplicate responses across relays are harmless: a session matches the first response to
/// a request and ignores the rest.
public actor RelayConnectionTransport: RelayTransport {
    private let relays: [RelayConnection]
    private var forwardingTasks: [Task<Void, Never>] = []
    private var eventContinuation: AsyncStream<Event>.Continuation?
    /// Number of relay message streams still feeding the current ``events()`` stream.
    private var activeRelayStreams = 0
    /// Incremented each time the event stream is rebuilt or torn down, so completions from a
    /// previous generation's forwarding tasks are ignored.
    private var generation = 0

    /// Creates a transport for the given relay URLs.
    ///
    /// By default each relay's sockets come from a ``URLSessionWebSocketFactory`` over
    /// `URLSession.shared`. Supply a custom ``WebSocketSessionFactory`` to put a session on a
    /// platform-native socket — for example an OkHttp-backed factory on Android — or on an
    /// in-memory fake in tests, so the session's relay round-trips never touch the network.
    /// - Parameters:
    ///   - relayURLs: The relays to connect to (typically the URLs from a connection URI).
    ///   - config: Timeout, keepalive, and reconnection behavior for each relay.
    ///   - webSocketFactory: Creates the transport for each relay's connection attempts (defaults
    ///     to a ``URLSessionWebSocketFactory`` over `URLSession.shared`).
    public init(
        relayURLs: [RelayURL],
        config: RelayConnectionConfig = .default,
        webSocketFactory: any WebSocketSessionFactory = URLSessionWebSocketFactory()
    ) {
        self.relays = relayURLs.map {
            RelayConnection(url: $0, config: config, webSocketFactory: webSocketFactory)
        }
    }

    /// Connects to every relay.
    /// - Throws: ``RelayConnection/Error/notConnected`` when no relay connects.
    public func connect() async throws(RelayConnection.Error) {
        var connected = 0
        for relay in relays {
            if (try? await relay.connect()) != nil {
                connected += 1
            }
        }
        guard connected > 0 else { throw .notConnected }
    }

    /// Opens the subscription on every relay.
    /// - Throws: ``RelayConnection/Error/notConnected`` when no relay accepts the request.
    public func subscribe(id: SubscriptionID, filters: [Filter]) async throws(RelayConnection.Error) {
        var subscribed = 0
        for relay in relays {
            if (try? await relay.subscribe(id: id, filters: filters)) != nil {
                subscribed += 1
            }
        }
        guard subscribed > 0 else { throw .notConnected }
    }

    public func unsubscribe(id: SubscriptionID) async {
        for relay in relays {
            await relay.unsubscribe(id: id)
        }
    }

    /// Sends the event to every relay, connecting first a relay that is not connected — a session
    /// connects the transport once, so a relay that dropped since is reconnected here even with
    /// auto-reconnect off.
    /// - Throws: ``RelayConnection/Error/notConnected`` when no relay accepts the send.
    public func send(_ event: Event) async throws(RelayConnection.Error) {
        var sent = 0
        for relay in relays {
            if await relay.state != .connected {
                try? await relay.connect()
            }
            if (try? await relay.send(.event(event))) != nil {
                sent += 1
            }
        }
        guard sent > 0 else { throw .notConnected }
    }

    public func events() -> AsyncStream<Event> {
        // Tear down any previous stream so its consumer isn't left hanging and its tasks don't leak.
        teardownEventStream()

        generation += 1
        let generation = generation
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        eventContinuation = continuation

        guard !relays.isEmpty else {
            continuation.finish()
            eventContinuation = nil
            return stream
        }

        activeRelayStreams = relays.count
        for relay in relays {
            let task = Task { [continuation, weak self] in
                for await message in await relay.messages() {
                    if case .event(_, let event) = message {
                        continuation.yield(event)
                    }
                }
                // The relay's stream ended (e.g. a dropped connection); finish once they all have.
                await self?.relayStreamEnded(generation: generation)
            }
            forwardingTasks.append(task)
        }
        return stream
    }

    public func disconnect() async {
        teardownEventStream()
        for relay in relays {
            await relay.disconnect()
        }
    }

    /// Cancels the forwarding tasks and finishes the current event stream, invalidating the
    /// generation so any in-flight task completions are ignored.
    private func teardownEventStream() {
        generation += 1
        for task in forwardingTasks {
            task.cancel()
        }
        forwardingTasks.removeAll()
        activeRelayStreams = 0
        eventContinuation?.finish()
        eventContinuation = nil
    }

    /// Records that one relay's message stream ended, finishing the event stream once they all have.
    private func relayStreamEnded(generation: Int) {
        guard generation == self.generation else { return }
        activeRelayStreams -= 1
        guard activeRelayStreams <= 0 else { return }
        eventContinuation?.finish()
        eventContinuation = nil
    }
}
