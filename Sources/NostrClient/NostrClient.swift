import Foundation
import NostrCore

/// Main entry point for the Nostr client library.
///
/// The public API is grouped into feature namespaces reached from the client — ``identity``,
/// ``relays``, ``events``, ``subscriptions``, ``routing``, ``messages``, ``groups``, and
/// ``lists``. Each is a lightweight `Sendable` façade defined in the adjacent `API/` directory,
/// and each conforms to a capability protocol so an app feature can depend on just the slice it
/// needs.
///
/// ```swift
/// let client = NostrClient()
/// try await client.identity.setPrivateKey(privateKeyHex)
/// try await client.relays.connect(to: ["wss://relay.damus.io"])
/// try await client.events.publishTextNote(content: "hello")
/// ```
///
/// This file holds the stored state, the initializers, and the signer primitives the façades
/// build on. The signer stays `private`; façades sign through `withSigner(_:)` rather than
/// reading it directly. The remaining shared stored properties are `internal` so those façades,
/// which live in separate files, can reach them.
public actor NostrClient {
    /// The relay pool managing all connections, reached publicly as ``NostrRelaysAPI/pool``.
    ///
    /// Immutable and `Sendable`, so the façades read it without hopping onto the actor.
    let pool: RelayPool

    /// The signer (optional, required for signing) — a local ``EventSigner``, which signs
    /// synchronously, or a remote NIP-46 signer, which signs via a relay round-trip. Every
    /// feature goes through the ``NostrSigning`` abstraction, so the two are interchangeable.
    private var activeSigner: (any NostrSigning)?

    /// The signer's public key, cached at set-time (a remote signer's `publicKey` is async).
    /// Readable module-wide so ``NostrIdentityAPI`` can surface it without a throwing lookup.
    private(set) var cachedPublicKey: String?

    /// How the client reacts to NIP-42 AUTH challenges, published as
    /// ``NostrIdentityAPI/authenticationMode``.
    var currentAuthenticationMode: AuthenticationMode = .automatic

    /// Subscription counter for generating unique IDs
    var subscriptionCounter: Int = 0

    /// Active subscriptions, keyed by subscription id.
    /// Named for the state it holds rather than the ``subscriptions`` namespace accessor.
    var openSubscriptions: [String: SubscriptionState] = [:]

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
        self.pool = relayPool
        self.relayListStore = RelayListStore(pool: relayPool, policy: gossipPolicy)
        self.dmRelayListStore = DirectMessageRelayListStore(pool: relayPool, policy: gossipPolicy)
    }

    // MARK: - Signer

    /// Installs a local signer, whose public key is available synchronously.
    ///
    /// Backs ``NostrIdentityAPI/setSigner(_:)-(EventSigner)``.
    func install(_ signer: EventSigner) async {
        activeSigner = signer
        cachedPublicKey = signer.publicKey
        await refreshAuthenticationResponder()
    }

    /// Installs a local or remote signer, resolving its public key once so ``cachedPublicKey``
    /// stays synchronous afterwards.
    ///
    /// Backs ``NostrIdentityAPI/setSigner(_:)-(any NostrSigning)``.
    func install(_ signer: any NostrSigning) async throws {
        cachedPublicKey = try await signer.publicKey
        activeSigner = signer
        await refreshAuthenticationResponder()
    }

    /// Whether a signer is configured, without exposing it.
    var hasSigner: Bool {
        activeSigner != nil
    }

    /// The signer's public key, for the helpers that cannot proceed without one.
    /// - Throws: ``NostrError/signerNotSet`` when no signer is set.
    func requiredPublicKey() throws -> String {
        guard let cachedPublicKey else { throw NostrError.signerNotSet }
        return cachedPublicKey
    }

    /// The signer's npub, or nil when no signer is set.
    /// Backs ``NostrIdentityAPI/npub``.
    func currentNpub() throws -> String? {
        guard let cachedPublicKey else { return nil }
        return try PublicKey(hex: cachedPublicKey).npub
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
    func signEvent(_ build: @Sendable (_ publicKey: String) throws -> UnsignedEvent) async throws -> Event {
        try await withSigner { signer, publicKey in try await signer.sign(build(publicKey)) }
    }

    /// Runs `body` with the configured signer and its cached public key.
    ///
    /// Keeps the signer — and, for a local one, the private key it holds — from escaping into the
    /// feature façades, which would otherwise be able to read it directly now that the API is
    /// split across files. The signer is handed over as ``NostrSigning``, so a helper written
    /// against it works with a local key and a remote NIP-46 signer alike; callers do the network
    /// publish after the closure returns.
    ///
    /// - Throws: ``NostrError/signerNotSet`` when no signer is set.
    func withSigner<T: Sendable>(
        _ body: @Sendable (_ signer: any NostrSigning, _ publicKey: String) async throws -> T
    ) async throws -> T {
        guard let activeSigner, let cachedPublicKey else {
            throw NostrError.signerNotSet
        }
        return try await body(activeSigner, cachedPublicKey)
    }
}
