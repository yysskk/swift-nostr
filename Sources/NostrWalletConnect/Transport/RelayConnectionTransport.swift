import Foundation

public import NostrClient

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
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        eventContinuation = continuation
        for relay in relays {
            let task = Task { [continuation] in
                for await message in await relay.messages() {
                    if case .event(_, let event) = message {
                        continuation.yield(event)
                    }
                }
            }
            forwardingTasks.append(task)
        }
        return stream
    }

    public func disconnect() async {
        for task in forwardingTasks {
            task.cancel()
        }
        forwardingTasks.removeAll()
        eventContinuation?.finish()
        eventContinuation = nil
        for relay in relays {
            await relay.disconnect()
        }
    }
}
