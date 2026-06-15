import Foundation

import NostrClient
public import NostrCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The default ``WalletConnectTransport``, backed by one or more `NostrClient` `RelayConnection`s.
///
/// A wallet connection usually targets a single relay, but a connection URI may list several; this
/// transport connects to all of them, sends each request to all, and merges their incoming events
/// into one stream. Duplicate responses across relays are harmless: ``WalletConnection`` matches the
/// first response to a request and ignores the rest.
public actor RelayConnectionTransport: WalletConnectTransport {
    private let relays: [RelayConnection]
    private var forwardingTasks: [Task<Void, Never>] = []
    private var eventContinuation: AsyncStream<Event>.Continuation?
    /// Number of relay message streams still feeding the current ``events()`` stream.
    private var activeRelayStreams = 0
    /// Incremented each time the event stream is rebuilt or torn down, so completions from a
    /// previous generation's forwarding tasks are ignored.
    private var generation = 0

    /// Creates a transport for the given relay URLs.
    /// - Parameters:
    ///   - relayURLs: The relays to connect to (typically the URLs from a ``WalletConnectURI``).
    ///   - urlSession: The URL session backing the WebSocket connections (defaults to `.shared`).
    public init(relayURLs: [URL], urlSession: URLSession = .shared) {
        self.relays = relayURLs.map { RelayConnection(url: $0, urlSession: urlSession) }
    }

    public func connect() async throws {
        var connected = 0
        for relay in relays {
            if (try? await relay.connect()) != nil {
                connected += 1
            }
        }
        guard connected > 0 else { throw WalletConnectError.notConnected }
    }

    public func subscribe(id: String, filters: [Filter]) async throws {
        var subscribed = 0
        for relay in relays {
            if (try? await relay.subscribe(subscriptionId: id, filters: filters)) != nil {
                subscribed += 1
            }
        }
        guard subscribed > 0 else { throw WalletConnectError.notConnected }
    }

    public func unsubscribe(id: String) async {
        for relay in relays {
            try? await relay.unsubscribe(subscriptionId: id)
        }
    }

    public func send(_ event: Event) async throws {
        var sent = 0
        for relay in relays {
            if (try? await relay.send(.event(event))) != nil {
                sent += 1
            }
        }
        guard sent > 0 else { throw WalletConnectError.notConnected }
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
