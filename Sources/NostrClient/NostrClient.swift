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

    /// The configured signer — a local key or a remote NIP-46 signer.
    private enum ActiveSigner {
        case local(EventSigner)
        case remote(any NostrSigning)
    }

    /// The event signer (optional, required for signing). A local ``EventSigner`` signs
    /// synchronously; a remote NIP-46 signer signs via a relay round-trip.
    private var activeSigner: ActiveSigner?

    /// The signer's public key, cached at set-time (a remote signer's `publicKey` is async).
    private var cachedPublicKey: String?

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

    /// Sets the signer for signing events.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the
    /// default), setting a signer also starts answering NIP-42 AUTH challenges
    /// with it on every relay in the pool.
    public func setSigner(_ signer: EventSigner) async {
        activeSigner = .local(signer)
        cachedPublicKey = signer.publicKey
        await refreshAuthenticationResponder()
    }

    /// Sets a local or remote signer for signing events.
    ///
    /// Accepts any ``NostrSigning`` — a local ``EventSigner`` or a remote NIP-46 signer (a
    /// "bunker"). The signer's ``NostrSigning/publicKey`` is resolved once here and cached, so
    /// ``publicKey`` and ``npub`` stay synchronous even for a remote signer. A remote signer can
    /// ``sign(_:)``, ``publish(_:strategy:)`` its signed events, and answer NIP-42 AUTH challenges;
    /// the convenience `publish*` and direct-message helpers still require a local key.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the default), setting a
    /// signer also starts answering NIP-42 AUTH challenges with it on every relay in the pool.
    public func setSigner(_ signer: any NostrSigning) async throws {
        cachedPublicKey = try await signer.publicKey
        activeSigner = (signer as? EventSigner).map(ActiveSigner.local) ?? .remote(signer)
        await refreshAuthenticationResponder()
    }

    /// Sets the signer from a private key hex string. See ``setSigner(_:)-(EventSigner)``.
    public func setPrivateKey(_ privateKeyHex: String) async throws {
        await setSigner(try EventSigner(privateKeyHex: privateKeyHex))
    }

    /// Sets the signer from an nsec. See ``setSigner(_:)-(EventSigner)``.
    public func setNsec(_ nsec: String) async throws {
        await setSigner(try EventSigner(nsec: nsec))
    }

    /// Whether a signer is configured, without exposing it.
    var hasSigner: Bool {
        activeSigner != nil
    }

    /// Returns the public key if a signer is set
    public var publicKey: String? {
        cachedPublicKey
    }

    /// Returns the npub if a signer is set
    public var npub: String? {
        get throws {
            guard let cachedPublicKey else { return nil }
            return try PublicKey(hex: cachedPublicKey).npub
        }
    }

    /// Signs `unsignedEvent` with the active signer (local synchronously, remote via relay
    /// round-trip), throwing ``NostrError/signerNotSet`` if none is set.
    func activeSign(_ unsignedEvent: UnsignedEvent) async throws -> Event {
        switch activeSigner {
        case .local(let signer): return try signer.sign(unsignedEvent)
        case .remote(let signer): return try await signer.sign(unsignedEvent)
        case nil: throw NostrError.signerNotSet
        }
    }

    /// Signs an event with the configured signer, local or remote.
    ///
    /// Build an ``UnsignedEvent`` with ``publicKey`` as its pubkey; combine with
    /// ``publish(_:strategy:)`` to author and publish an event with a remote NIP-46 signer.
    /// - Parameter unsignedEvent: The event to sign; its `pubkey` should be ``publicKey``.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``NostrError/signerNotSet`` if no signer is set, plus anything the signer throws.
    public func sign(_ unsignedEvent: UnsignedEvent) async throws -> Event {
        try await activeSign(unsignedEvent)
    }

    /// Runs `body` with the configured local signer.
    ///
    /// Keeps the `EventSigner` — and the private key it holds — from escaping into the feature
    /// extensions, which would otherwise be able to read it directly now that the type is split
    /// across files. Local signing is synchronous, so callers extract the signed event inside the
    /// closure and perform the network publish afterwards.
    ///
    /// - Throws: ``NostrError/signerNotSet`` when no signer is set, and
    ///   ``NostrError/localSignerRequired`` when a remote signer is set — the convenience `publish*`
    ///   and direct-message helpers that call this need a local key and cannot use a remote signer.
    func withSigner<T>(_ body: (EventSigner) throws -> T) throws -> T {
        switch activeSigner {
        case .local(let signer): return try body(signer)
        case .remote: throw NostrError.localSignerRequired
        case nil: throw NostrError.signerNotSet
        }
    }
}
