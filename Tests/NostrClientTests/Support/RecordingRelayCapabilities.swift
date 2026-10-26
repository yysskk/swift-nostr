import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrRelaysAPI`` that implements only the ``NostrRelayManaging`` primitives: it
/// keeps an in-memory pool of unconnected ``RelayConnection``s and records every call in order, so
/// the protocol extension can be exercised without sockets.
///
/// Like ``RelayPool``, re-adding a relay already in the pool returns the existing connection and
/// ignores the new configuration.
actor RecordingRelayCapabilities: NostrRelayManaging {
    /// One primitive call, in the order the stub received it.
    enum Call: Sendable, Equatable {
        /// `add(_:config:)`, with whether a configuration was passed.
        case add(RelayURL, hasConfig: Bool)
        case remove(RelayURL)
        case connect
        case disconnect
        case clearDeduplicationCache
    }

    /// What every connect throws, or nil to succeed.
    let connectError: NostrError?

    private(set) var calls: [Call] = []
    /// The configuration passed with each add, keyed by relay, for the adds that passed one.
    private(set) var configs: [RelayURL: RelayConnectionConfig] = [:]
    private var pool: [RelayURL: RelayConnection] = [:]

    init(connectError: NostrError? = nil) {
        self.connectError = connectError
    }

    // MARK: - NostrRelayManaging

    func add(_ url: RelayURL, config: RelayConnectionConfig?) async -> RelayConnection {
        calls.append(.add(url, hasConfig: config != nil))
        if let existing = pool[url] {
            return existing
        }
        let connection = RelayConnection(url: url, config: config ?? .default)
        pool[url] = connection
        configs[url] = config
        return connection
    }

    func remove(_ url: RelayURL) async {
        calls.append(.remove(url))
        pool[url] = nil
    }

    func connect() async throws {
        calls.append(.connect)
        if let connectError {
            throw connectError
        }
    }

    func disconnect() async {
        calls.append(.disconnect)
    }

    var connections: [RelayConnection] {
        Array(pool.values)
    }

    func connectedRelayCount() async -> Int {
        0
    }

    func relay(for url: RelayURL) async -> RelayConnection? {
        pool[url]
    }

    func clearDeduplicationCache() async {
        calls.append(.clearDeduplicationCache)
    }
}
