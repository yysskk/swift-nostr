import Foundation
import NostrCore

/// Main entry point for the Nostr client library.
///
/// The client's behavior is organized into feature extensions in adjacent
/// `NostrClient+*.swift` files (relay management, publishing, direct messages,
/// subscriptions, fetches, and NIP-65 outbox/gossip). This file holds the stored
/// state, the initializers, and signer management.
///
/// The `EventSigner` (and the private key it holds) stays `private`; feature
/// extensions sign through ``withSigner(_:)`` rather than reading the signer
/// directly. The remaining shared stored properties are `internal` so those
/// extensions, which live in separate files, can reach them.
public actor NostrClient {
    /// The relay pool managing all connections
    public let relayPool: RelayPool

    /// The event signer (optional, required for publishing)
    private var signer: EventSigner?

    /// How the client reacts to NIP-42 AUTH challenges. `internal(set)` so
    /// ``setAuthenticationMode(_:)``, which lives in the authentication
    /// extension file, can assign it.
    public internal(set) var authenticationMode: AuthenticationMode = .automatic

    /// Subscription counter for generating unique IDs
    var subscriptionCounter: Int = 0

    /// Active subscriptions
    var subscriptions: [String: SubscriptionState] = [:]

    /// Per-pubkey NIP-65 relay list cache and outbox/gossip resolver
    let relayListStore: RelayListStore

    /// Per-pubkey NIP-17 DM relay list (kind 10050) cache and inbox resolver
    let dmRelayListStore: DirectMessageRelayListStore

    public init(
        relayPoolConfig: RelayPoolConfig = .default,
        gossipPolicy: GossipRelayPolicy = .addAndConnect
    ) {
        self.init(relayPool: RelayPool(config: relayPoolConfig), gossipPolicy: gossipPolicy)
    }

    /// Creates a client whose relays use the given WebSocket transport.
    ///
    /// Supply a custom ``WebSocketSessionFactory`` to run on a platform without
    /// `URLSession` WebSocket support — for example an OkHttp-backed factory on Android.
    /// On Apple platforms the default ``init(relayPoolConfig:gossipPolicy:)`` already uses
    /// `URLSession`, so this initializer is only needed when overriding the transport.
    public init(
        relayPoolConfig: RelayPoolConfig = .default,
        gossipPolicy: GossipRelayPolicy = .addAndConnect,
        webSocketFactory: any WebSocketSessionFactory
    ) {
        self.init(
            relayPool: RelayPool(config: relayPoolConfig, webSocketFactory: webSocketFactory),
            gossipPolicy: gossipPolicy
        )
    }

    /// Designated initializer shared by the public initializer and by tests, which inject a
    /// ``RelayPool`` built with a fake transport so the client can be exercised without a network.
    init(relayPool: RelayPool, gossipPolicy: GossipRelayPolicy = .addAndConnect) {
        self.relayPool = relayPool
        self.relayListStore = RelayListStore(pool: relayPool, policy: gossipPolicy)
        self.dmRelayListStore = DirectMessageRelayListStore(pool: relayPool, policy: gossipPolicy)
    }

    // MARK: - Signer

    /// Sets the signer for publishing events.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the
    /// default), setting a signer also starts answering NIP-42 AUTH challenges
    /// with it on every relay in the pool.
    public func setSigner(_ signer: EventSigner) async {
        self.signer = signer
        await refreshAuthenticationResponder()
    }

    /// Sets the signer from a private key hex string. See ``setSigner(_:)``.
    public func setPrivateKey(_ privateKeyHex: String) async throws {
        await setSigner(try EventSigner(privateKeyHex: privateKeyHex))
    }

    /// Sets the signer from an nsec. See ``setSigner(_:)``.
    public func setNsec(_ nsec: String) async throws {
        await setSigner(try EventSigner(nsec: nsec))
    }

    /// Whether a signer is configured, without exposing it.
    var hasSigner: Bool {
        signer != nil
    }

    /// Returns the public key if a signer is set
    public var publicKey: String? {
        signer?.publicKey
    }

    /// Returns the npub if a signer is set
    public var npub: String? {
        signer?.npub
    }

    /// Runs `body` with the configured signer, throwing ``NostrError/signerNotSet`` if none is set.
    ///
    /// Keeps the `EventSigner` — and the private key it holds — from escaping into the feature
    /// extensions, which would otherwise be able to read it directly now that the type is split
    /// across files. Signing is synchronous, so callers extract the signed event inside the
    /// closure and perform the network publish afterwards.
    func withSigner<T>(_ body: (EventSigner) throws -> T) throws -> T {
        guard let signer else { throw NostrError.signerNotSet }
        return try body(signer)
    }
}
