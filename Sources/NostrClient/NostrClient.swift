import Foundation
import NostrCore

/// Main entry point for the Nostr client library.
///
/// The client's behavior is organized into feature extensions in adjacent
/// `NostrClient+*.swift` files (relay management, publishing, direct messages,
/// subscriptions, fetches, and NIP-65 outbox/gossip). This file holds the stored
/// state, the initializers, and signer management.
///
/// The signer stays `private`; feature extensions sign through ``withSigner(_:)``
/// rather than reading it directly. The remaining shared stored properties are
/// `internal` so those extensions, which live in separate files, can reach them.
public actor NostrClient {
    /// The relay pool managing all connections
    public let relayPool: RelayPool

    /// The signer (optional, required for signing) — a local ``EventSigner``, which signs
    /// synchronously, or a remote NIP-46 signer, which signs via a relay round-trip. Every
    /// feature goes through the ``NostrSigning`` abstraction, so the two are interchangeable.
    private var activeSigner: (any NostrSigning)?

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
        activeSigner = signer
        cachedPublicKey = signer.publicKey
        await refreshAuthenticationResponder()
    }

    /// Sets a local or remote signer for signing events.
    ///
    /// Accepts any ``NostrSigning`` — a local ``EventSigner`` or a remote NIP-46 signer (a
    /// "bunker"). The signer's ``NostrSigning/publicKey`` is resolved once here and cached, so
    /// ``publicKey`` and ``npub`` stay synchronous even for a remote signer. Every feature works
    /// with either kind: signing, publishing, the convenience `publish*` helpers, NIP-17 direct
    /// messages, NIP-51 private list items, and NIP-42 AUTH challenges.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the default), setting a
    /// signer also starts answering NIP-42 AUTH challenges with it on every relay in the pool.
    public func setSigner(_ signer: any NostrSigning) async throws {
        cachedPublicKey = try await signer.publicKey
        activeSigner = signer
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

    /// The signer's public key, for the helpers that cannot proceed without one.
    /// - Throws: ``NostrError/signerNotSet`` when no signer is set.
    func requiredPublicKey() throws -> String {
        guard let cachedPublicKey else { throw NostrError.signerNotSet }
        return cachedPublicKey
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
        try await withSigner { signer, _ in try await signer.sign(unsignedEvent) }
    }

    /// Builds an event for the active signer's public key and signs it with that signer.
    ///
    /// The convenience `publish*` helpers all have this shape: they differ only in the event they
    /// build, and every one of them works with a local or a remote signer.
    func signEvent(_ build: (String) throws -> UnsignedEvent) async throws -> Event {
        try await withSigner { signer, publicKey in try await signer.sign(build(publicKey)) }
    }

    /// Signs an event with the configured signer, local or remote.
    ///
    /// Build an ``UnsignedEvent`` with ``publicKey`` as its pubkey; combine with
    /// ``publish(_:strategy:)`` to author and publish an event this library has no helper for.
    /// - Parameter unsignedEvent: The event to sign; its `pubkey` should be ``publicKey``.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``NostrError/signerNotSet`` if no signer is set, plus anything the signer throws.
    public func sign(_ unsignedEvent: UnsignedEvent) async throws -> Event {
        try await activeSign(unsignedEvent)
    }

    /// Runs `body` with the configured signer and its cached public key.
    ///
    /// Keeps the signer — and, for a local one, the private key it holds — from escaping into the
    /// feature extensions, which would otherwise be able to read it directly now that the type is
    /// split across files. The signer is handed over as ``NostrSigning``, so a helper written
    /// against it works with a local key and a remote NIP-46 signer alike; callers do the network
    /// publish after the closure returns.
    ///
    /// - Throws: ``NostrError/signerNotSet`` when no signer is set.
    func withSigner<T>(_ body: (any NostrSigning, String) async throws -> T) async throws -> T {
        guard let activeSigner, let cachedPublicKey else {
            throw NostrError.signerNotSet
        }
        return try await body(activeSigner, cachedPublicKey)
    }
}
