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
/// try await client.identity.setSigner(EventSigner(nsec: "nsec1..."))
/// try await client.relays.connect(to: [RelayURL(string: "wss://relay.damus.io")])
/// try await client.events.publishTextNote(content: "hello")
/// ```
///
/// This file holds the stored state, the initializers, and the signer primitives the façades
/// build on. The signer stays `private`; façades sign through `withSigner(_:)` rather than
/// reading it directly. The remaining shared stored properties are `internal` so those façades,
/// which live in separate files, can reach them.
public actor NostrClient {
    /// Client behavior: the relay pool, how gossip routing brings relays into it, and how far.
    public struct Config: Sendable, Hashable {
        /// The relay pool's configuration. Default: ``RelayPoolConfig/default``.
        public var relayPool: RelayPoolConfig

        /// How outbox/inbox routing brings a user's declared relays into the pool. Default:
        /// ``GossipRelayPolicy/addAndConnect``.
        public var gossipPolicy: GossipRelayPolicy

        /// The most relays a single gossip resolution may add to the pool and connect. Default: 8.
        ///
        /// One resolution is the relay set computed for one outbox publish or read, or for one
        /// recipient's NIP-17 DM inbox. Relays already in the pool are always used and never count
        /// against this limit; it bounds only how many *new* sockets routing across many users'
        /// relay lists may open at once. Which of the surplus relays are skipped is unspecified.
        ///
        /// Zero or a negative value adds no relays, so gossip resolution uses only relays already
        /// in the pool — the same outcome as ``GossipRelayPolicy/requirePresent``. Under
        /// ``GossipRelayPolicy/requirePresent`` this limit has no effect.
        public var maximumGossipRelaysPerResolve: Int

        /// The default configuration: ``RelayPoolConfig/default``, ``GossipRelayPolicy/addAndConnect``,
        /// and at most 8 new relays per gossip resolution.
        public static let `default` = Config()

        /// Creates a client configuration.
        /// - Parameters:
        ///   - relayPool: The relay pool's configuration.
        ///   - gossipPolicy: How outbox/inbox routing brings declared relays into the pool.
        ///   - maximumGossipRelaysPerResolve: The most relays one gossip resolution may add and
        ///     connect; zero or less adds none.
        public init(
            relayPool: RelayPoolConfig = .default,
            gossipPolicy: GossipRelayPolicy = .addAndConnect,
            maximumGossipRelaysPerResolve: Int = 8
        ) {
            self.relayPool = relayPool
            self.gossipPolicy = gossipPolicy
            self.maximumGossipRelaysPerResolve = maximumGossipRelaysPerResolve
        }
    }

    /// The configuration this client was created with.
    ///
    /// ``Config/relayPool`` mirrors the pool's own ``RelayPool/config``.
    public nonisolated let config: Config

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
    private(set) var cachedPublicKey: PublicKey?

    /// Bumped on entry to every ``install(_:)`` and ``uninstallSigner()``, so a remote install
    /// whose public key resolves after a later call started can tell it was superseded.
    private var signerGeneration = 0

    /// How the client reacts to NIP-42 AUTH challenges, published as
    /// ``NostrIdentityAPI/authenticationMode``.
    var currentAuthenticationMode: AuthenticationMode = .automatic

    /// Per-public-key NIP-65 relay list cache and outbox/gossip resolver
    let relayListStore: RelayListStore

    /// Per-public-key NIP-17 DM relay list (kind 10050) cache and inbox resolver
    let dmRelayListStore: DirectMessageRelayListStore

    /// Creates a client.
    ///
    /// By default every relay connection's sockets come from a ``URLSessionWebSocketFactory`` over
    /// `URLSession.shared`. Supply a custom ``WebSocketSessionFactory`` to run on a platform without
    /// working `URLSession` WebSocket support — for example an OkHttp-backed factory on Android.
    /// - Parameters:
    ///   - config: The relay pool, gossip policy, and gossip relay limit.
    ///   - webSocketFactory: Creates the transport for each relay connection (defaults to a
    ///     ``URLSessionWebSocketFactory`` over `URLSession.shared`).
    public init(
        config: Config = .default,
        webSocketFactory: any WebSocketSessionFactory = URLSessionWebSocketFactory()
    ) {
        let pool = RelayPool(config: config.relayPool, webSocketFactory: webSocketFactory)
        self.init(
            relayPool: pool,
            gossipPolicy: config.gossipPolicy,
            maximumGossipRelaysPerResolve: config.maximumGossipRelaysPerResolve
        )
    }

    /// Designated initializer shared by the public initializer and by tests, which inject a
    /// ``RelayPool`` built with a fake transport so the client can be exercised without a network.
    ///
    /// ``config`` takes its ``Config/relayPool`` from `relayPool`, so it describes the injected pool.
    init(
        relayPool: RelayPool,
        gossipPolicy: GossipRelayPolicy = Config.default.gossipPolicy,
        maximumGossipRelaysPerResolve: Int = Config.default.maximumGossipRelaysPerResolve
    ) {
        self.config = Config(
            relayPool: relayPool.config,
            gossipPolicy: gossipPolicy,
            maximumGossipRelaysPerResolve: maximumGossipRelaysPerResolve
        )
        let limit = maximumGossipRelaysPerResolve
        self.pool = relayPool
        self.relayListStore = RelayListStore(
            pool: relayPool, policy: gossipPolicy, maximumGossipRelaysPerResolve: limit)
        self.dmRelayListStore = DirectMessageRelayListStore(
            pool: relayPool, policy: gossipPolicy, maximumGossipRelaysPerResolve: limit)
    }

    // MARK: - Signer

    /// Installs a local or remote signer, resolving its public key once so ``cachedPublicKey``
    /// stays synchronous afterwards.
    ///
    /// The last call to start wins: each call to this or ``uninstallSigner()`` takes a new
    /// generation on entry, before any suspension. A local ``EventSigner`` is swapped in at once. A
    /// remote signer is swapped in only if no later call started while its public key resolved;
    /// otherwise this returns without changing anything.
    ///
    /// Backs ``NostrIdentityAPI/setSigner(_:)``.
    func install(_ signer: some NostrSigning) async throws {
        signerGeneration += 1
        let generation = signerGeneration
        let publicKey: PublicKey
        if let local = signer as? EventSigner {
            publicKey = local.publicKey
        } else {
            publicKey = try await signer.publicKey
            guard generation == signerGeneration else { return }
        }
        activeSigner = signer
        cachedPublicKey = publicKey
        await refreshAuthenticationResponder()
    }

    /// Clears the signer and its cached public key, and with them the pool-wide AUTH responder.
    ///
    /// Backs ``NostrIdentityAPI/removeSigner()``.
    func uninstallSigner() async {
        signerGeneration += 1
        activeSigner = nil
        cachedPublicKey = nil
        await refreshAuthenticationResponder()
    }

    /// Whether a signer is configured, without exposing it.
    var hasSigner: Bool {
        activeSigner != nil
    }

    /// The signer's public key, for the helpers that cannot proceed without one.
    /// - Throws: ``NostrClient/Error/signerNotSet`` when no signer is set.
    func requiredPublicKey() throws(Error) -> PublicKey {
        guard let cachedPublicKey else { throw .signerNotSet }
        return cachedPublicKey
    }

    /// Signs `template` as the active signer's public key (local synchronously, remote via relay
    /// round-trip), throwing ``NostrClient/Error/signerNotSet`` if none is set.
    ///
    /// The cached public key is used, so a remote signer is not asked for it again.
    func sign(_ template: EventTemplate) async throws -> Event {
        try await withSigner { signer, publicKey in
            try await signer.sign(UnsignedEvent(template, publicKey: publicKey))
        }
    }

    /// Runs `body` with the configured signer and its cached public key.
    ///
    /// Keeps the signer — and, for a local one, the private key it holds — from escaping into the
    /// feature façades, which would otherwise be able to read it directly now that the API is
    /// split across files. The signer is handed over as ``NostrSigning``, so a helper written
    /// against it works with a local key and a remote NIP-46 signer alike; callers do the network
    /// publish after the closure returns.
    ///
    /// - Throws: ``NostrClient/Error/signerNotSet`` when no signer is set, plus anything `body`
    ///   throws.
    func withSigner<T: Sendable>(
        _ body: @Sendable (_ signer: any NostrSigning, _ publicKey: PublicKey) async throws -> T
    ) async throws -> T {
        guard let activeSigner, let cachedPublicKey else {
            throw Error.signerNotSet
        }
        return try await body(activeSigner, cachedPublicKey)
    }
}

// MARK: - Error
extension NostrClient {
    /// Why a ``NostrClient`` operation failed before reaching a relay or the signer.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The operation needs a signer and none is set.
        case signerNotSet

        public var errorDescription: String? {
            switch self {
            case .signerNotSet:
                return "No signer is set — call setSigner(_:) first"
            }
        }
    }
}
