import Foundation
import NostrCore

// Capability protocols — one per feature namespace on `NostrClient`.
//
// An app feature declares the slice of the client it needs (`any NostrMessaging` rather than
// `NostrClient`), which keeps the dependency honest and makes the feature testable against a
// stub instead of a live relay pool:
//
//     struct ChatViewModel {
//         let messages: any NostrMessaging
//     }
//
//     ChatViewModel(messages: client.messages)
//
// A protocol's requirements are its primitives: the minimal operations everything else is built
// from, each spelling out every parameter, since Swift does not allow default argument values on
// protocol requirements. The conveniences — NIP helpers and short forms of the primitives — live
// in a public extension of the protocol (`Capabilities+<Feature>.swift`), carry the defaults, and
// are built only on the primitives. The concrete namespaces inherit them, so a stub implements only
// the primitives and a call through `any NostrEventPublishing` is as short as one through
// `client.events`.

// MARK: - Identity

/// Managing the signer the client authors events with, and proving it to relays (NIP-42).
/// Implemented by ``NostrIdentityAPI``.
///
/// The requirements are the primitives; ``setPrivateKey(_:)`` and ``setNsec(_:)`` are provided by
/// an extension built on ``setSigner(_:)-(EventSigner)``.
public protocol NostrIdentityProviding: Sendable {
    /// Sets a local signer.
    ///
    /// While ``authenticationMode`` is ``AuthenticationMode/automatic`` (the default), setting a
    /// signer also starts answering NIP-42 AUTH challenges with it on every relay in the pool.
    /// - Parameter signer: The local signer to author events with.
    func setSigner(_ signer: EventSigner) async

    /// Sets a local or remote (NIP-46) signer.
    ///
    /// The signer's ``NostrSigning/publicKey`` is resolved once here and cached, so ``publicKey``
    /// stays a single actor hop even for a remote signer.
    /// - Parameter signer: The signer to author events with — a local ``EventSigner`` or a remote
    ///   NIP-46 signer.
    /// - Throws: Anything the signer throws while resolving its public key.
    func setSigner(_ signer: any NostrSigning) async throws

    /// The public key events are authored under, or nil when no signer is set.
    var publicKey: PublicKey? { get async }

    /// Signs an event template with the configured signer.
    func sign(_ template: EventTemplate) async throws -> Event
    /// Encrypts `plaintext` to `recipientPublicKey` with NIP-44 as the configured signer.
    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String
    /// Decrypts a NIP-44 payload from `senderPublicKey` with the configured signer.
    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String

    /// How the client reacts to relay AUTH challenges.
    var authenticationMode: AuthenticationMode { get async }
    /// Sets how the client reacts to relay AUTH challenges.
    func setAuthenticationMode(_ mode: AuthenticationMode) async
    /// Answers one relay's pending AUTH challenge.
    func authenticate(relayURL: RelayURL) async throws
}

// MARK: - Relays

/// Managing which relays the client talks to and whether they are connected.
/// Implemented by ``NostrRelaysAPI``.
///
/// The requirements are the primitives; ``add(_:)-(RelayURL)``, ``add(_:)-(Sequence<RelayURL>)``,
/// ``connect(to:)``, and ``relayCount`` are provided by an extension built on them.
///
/// Deliberately does not vend the underlying ``RelayPool``: handing it over would give a
/// relay-management dependency the pool's publish, subscribe, and count as well, and would force
/// every stub to stand up a real pool. Take ``NostrRelaysAPI`` concretely when you need
/// ``NostrRelaysAPI/pool``.
public protocol NostrRelayManaging: Sendable {
    /// Adds a relay with a per-relay connection configuration, or the pool's default (nil).
    ///
    /// Relay URLs compare by their canonical form, so re-adding a relay already in the pool returns
    /// the existing connection and ignores `config`.
    /// - Parameters:
    ///   - url: The relay to add.
    ///   - config: The relay's connection configuration, or nil for the pool config's
    ///     ``RelayPoolConfig/defaultRelayConfig``.
    /// - Returns: The relay's connection in the pool.
    @discardableResult
    func add(_ url: RelayURL, config: RelayConnectionConfig?) async -> RelayConnection
    /// Removes a relay from the pool, disconnecting it; removing an absent relay is a no-op.
    func remove(_ url: RelayURL) async

    /// Connects to all relays in the pool.
    /// - Throws: ``NostrError/connectionFailed(_:)`` if every relay in the pool fails to connect;
    ///   partial connection failures are tolerated.
    func connect() async throws
    /// Disconnects from all relays, ending every open subscription.
    func disconnect() async

    /// Every relay connection in the pool, in no guaranteed order.
    var connections: [RelayConnection] { get async }
    /// The number of relays currently connected.
    func connectedRelayCount() async -> Int
    /// The pool's connection for a relay URL, or nil when it is not in the pool.
    func relay(for url: RelayURL) async -> RelayConnection?
    /// Clears every subscription's event deduplication cache in the relay pool.
    func clearDeduplicationCache() async
}

// MARK: - Events

/// Authoring and publishing events. Implemented by ``NostrEventsAPI``.
///
/// The requirements are the two publish primitives; the NIP helpers (``publishTextNote(content:tags:strategy:)``,
/// ``publishReply(to:content:relayURL:strategy:)``, …) and the short forms of the primitives are
/// provided by an extension built on them.
public protocol NostrEventPublishing: Sendable {
    /// Signs `template` with the configured signer and publishes it to the whole pool (nil) or to the
    /// given relays.
    ///
    /// Targeting follows ``publish(_:to:strategy:)-(Event,Set<RelayURL>?,_)``: an empty set always throws, and
    /// targets not in the pool are skipped.
    /// - Parameters:
    ///   - template: The event to sign and publish.
    ///   - relayURLs: The relays to publish to, or nil for the whole pool.
    ///   - strategy: How many relay acknowledgments to wait for before returning, or nil for the
    ///     pool config's ``RelayPoolConfig/defaultPublishStrategy``.
    /// - Returns: The signed event together with the per-relay publish outcome.
    /// - Throws: ``NostrError/signerNotSet`` if no signer is set, anything the signer throws, or the
    ///   errors of ``publish(_:to:strategy:)-(Event,Set<RelayURL>?,_)``.
    @discardableResult
    func publish(
        _ template: EventTemplate, to relayURLs: Set<RelayURL>?, strategy: PublishStrategy?
    ) async throws -> PublishedEvent

    /// Publishes an already-signed event to the whole pool (nil) or to the given relays.
    ///
    /// Pass relays to target a subset — for example, an event signed by a separate key that should
    /// reach only a few named relays. An empty set always throws, so an accidentally-empty computed
    /// list never fans out to the whole pool. Targets not in the pool are skipped, not connected on
    /// demand: add them with ``NostrRelaysAPI/add(_:config:)`` first.
    /// - Parameters:
    ///   - event: The already-signed event to publish.
    ///   - relayURLs: The relays to publish to, or nil for the whole pool.
    ///   - strategy: How many relay acknowledgments to wait for before returning, or nil for the
    ///     pool config's ``RelayPoolConfig/defaultPublishStrategy``.
    /// - Returns: The per-relay outcome of the publish, keyed by relay URL.
    /// - Throws: ``NostrError/noRelaysInPool`` when broadcasting to an empty pool,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool
    ///   (including an empty set), the last relay error if no targeted relay accepts the event,
    ///   or ``NostrError/relayError(_:)`` if a `.quorum` strategy cannot be satisfied.
    @discardableResult
    func publish(_ event: Event, to relayURLs: Set<RelayURL>?, strategy: PublishStrategy?) async throws -> PublishResult
}

/// Reading stored events one time, without holding a subscription open.
/// Implemented by ``NostrEventsAPI``.
///
/// The requirements are the fetch and count primitives; the lookups (``fetchEvent(id:timeout:)``,
/// ``fetchMetadata(publicKey:timeout:)``, …) and the short forms of the primitives are provided by
/// an extension built on them.
public protocol NostrEventFetching: Sendable {
    /// Fetches events matching `filters` from the whole pool (nil) or the given relays, waiting for
    /// every targeted relay to send EOSE or for `timeout`, whichever comes first.
    ///
    /// Targets not in the pool are skipped; an empty set always throws.
    /// - Parameters:
    ///   - filters: The filters to match.
    ///   - relayURLs: The relays to fetch from, or nil for the whole pool.
    ///   - timeout: How long to wait for relays to finish, or nil for
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The events received, deduplicated across relays.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty, or
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool
    ///   (including an empty set). Both are thrown before anything is sent to a relay.
    func fetch(filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> [Event]

    /// Requests the number of events matching `filters` (NIP-45 COUNT) from the whole pool (nil) or
    /// the given relays.
    ///
    /// Returns the maximum count the targeted relays report — each relay's count is a lower bound on
    /// the events it holds, so the maximum is the best single estimate. Targets not in the pool are
    /// skipped; an empty set always throws. For per-relay results use
    /// ``RelayPool/countEvents(matching:from:timeout:)`` on ``NostrRelaysAPI/pool``.
    /// - Parameters:
    ///   - filters: The filters to count.
    ///   - relayURLs: The relays to query, or nil for the whole pool.
    ///   - timeout: How long to wait for relays to finish, or nil for
    ///     ``RelayPoolConfig/queryTimeout``.
    /// - Returns: The highest count any targeted relay reported.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool, or the
    ///   last relay error when no targeted relay answered.
    func countEvents(matching filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> Int
}

// MARK: - Subscriptions

/// Opening live subscriptions. Implemented by ``NostrSubscriptionsAPI``.
///
/// The requirements are the subscribe and unsubscribe primitives; ``events(filters:bufferingPolicy:)``,
/// the feeds (``userTimeline(publicKey:limit:)``, ``globalFeed(limit:)``, …), and the short forms of
/// ``subscribe(filters:to:bufferingPolicy:)-(_,Set<RelayURL>?,_)`` are provided by an extension
/// built on them.
public protocol NostrSubscribing: Sendable {
    /// Opens a subscription on the whole pool (nil) or the given relays, as an async sequence of
    /// relay-aware events.
    ///
    /// Targets not in the pool are skipped; an empty set always throws. Iteration termination
    /// (breaking out of the loop, task cancellation, or discarding the sequence) sends CLOSE to the
    /// relays.
    /// - Parameters:
    ///   - filters: The NIP-01 filters the relays match events against.
    ///   - relayURLs: The relays to subscribe on, or nil for the whole pool.
    ///   - bufferingPolicy: How items are buffered while the consumer is slower than the relays.
    ///     Use `.bufferingNewest(n)` for firehose subscriptions where memory matters.
    /// - Returns: The subscription.
    /// - Throws: ``NostrError/noRelaysInPool`` when the pool is empty,
    ///   ``NostrError/noMatchingRelays(_:)`` when none of the targeted URLs are in the pool
    ///   (including an empty set), or ``NostrError/relayError(_:)`` when every relay fails to
    ///   subscribe.
    func subscribe(
        filters: [Filter],
        to relayURLs: Set<RelayURL>?,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    ) async throws -> SubscriptionSequence

    /// Closes one subscription; a no-op for unknown IDs.
    func unsubscribe(subscriptionID: String) async
    /// Closes every open subscription.
    func unsubscribeAll() async
}

// MARK: - Routing

/// Discovering where a user's events live (NIP-65) and where their messages go (NIP-17),
/// and routing by those lists. Implemented by ``NostrRoutingAPI``.
public protocol NostrRelayRouting: Sendable {
    /// Fetches and caches a user's NIP-65 relay list.
    func fetchRelayList(for publicKey: PublicKey, timeout: Duration?) async throws -> RelayListMetadata?
    /// The cached NIP-65 relay list for a public key, without a network fetch.
    func cachedRelayList(for publicKey: PublicKey) async -> RelayListMetadata?
    /// Publishes the current user's NIP-65 relay list.
    @discardableResult
    func publishRelayList(
        _ relayList: RelayListMetadata, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes the current user's NIP-65 relay list from read/write URLs.
    @discardableResult
    func publishRelayList(
        read: [RelayURL], write: [RelayURL], strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Subscribes to authors on their own WRITE relays (the outbox model).
    func subscribeOutbox(
        authors: [PublicKey], kinds: [Event.Kind], limit: Int?
    ) async throws -> SubscriptionSequence
    /// Publishes a signed event to the author's WRITE relays and its mentions' READ relays.
    @discardableResult
    func publishGossip(_ event: Event, strategy: PublishStrategy?) async throws -> PublishResult

    /// Fetches and caches a user's NIP-17 DM relay list.
    func fetchDirectMessageRelayList(
        for publicKey: PublicKey, timeout: Duration?
    ) async throws -> DirectMessageRelayList?
    /// The cached NIP-17 DM relay list for a public key, without a network fetch.
    func cachedDirectMessageRelayList(for publicKey: PublicKey) async -> DirectMessageRelayList?
    /// Publishes the current user's NIP-17 DM relay list.
    @discardableResult
    func publishDirectMessageRelayList(
        _ relayList: DirectMessageRelayList, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes the current user's NIP-17 DM relay list from relay URLs.
    @discardableResult
    func publishDirectMessageRelayList(
        relays: [RelayURL], strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Connects the current user's own DM inbox relays so messages sent there arrive.
    @discardableResult
    func connectDirectMessageInboxRelays() async throws -> Set<RelayURL>
}

// MARK: - Messages

/// Sending and receiving NIP-17 private direct messages. Implemented by ``NostrMessagesAPI``.
public protocol NostrMessaging: Sendable {
    /// Sends a private direct message.
    @discardableResult
    func send(
        _ content: String,
        to recipientPublicKey: PublicKey,
        subject: String?,
        replyTo: EventID?,
        expiration: Timestamp?,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult
    /// Sends a NIP-25 reaction to a received message.
    @discardableResult
    func react(
        to message: DirectMessage, reaction: String, expiration: Timestamp?, strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult
    /// Sends a kind-15 encrypted file message.
    @discardableResult
    func sendFile(
        url: String,
        mimeType: String,
        encryption: EncryptedFile,
        size: Int?,
        dimensions: String?,
        blurhash: String?,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult
    /// Sends a rumor of any kind gift-wrapped, routed like a direct message.
    @discardableResult
    func sendGiftWrapped(
        _ rumor: UnsignedEvent, to recipientPublicKey: PublicKey, expiration: Timestamp?, strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult

    /// Unwraps a received gift wrap as a message.
    func parse(_ giftWrap: Event) async throws -> DirectMessage
    /// Unwraps a received gift wrap as a reaction.
    func parseReaction(_ giftWrap: Event) async throws -> DirectMessageReaction
    /// Unwraps a received gift wrap as a file message.
    func parseFile(_ giftWrap: Event) async throws -> DirectMessageFile
    /// Unwraps a received gift wrap into whichever payload it carries.
    func parsePayload(_ giftWrap: Event) async throws -> DirectMessagePayload

    /// Subscribes to the current user's messages, already unwrapped.
    func subscribe(limit: Int) async throws -> DirectMessageSequence
    /// Subscribes to the current user's messages and reactions, already unwrapped.
    func payloads(limit: Int) async throws -> DirectMessagePayloadSequence
    /// Subscribes to the raw gift wraps addressed to the current user.
    func giftWraps(limit: Int) async throws -> SubscriptionSequence
}

// MARK: - Groups

/// Joining, posting to, moderating, and reading NIP-29 relay-based groups.
/// Implemented by ``NostrGroupsAPI``.
public protocol NostrGroupManaging: Sendable {
    /// Requests to join a group.
    @discardableResult
    func join(
        _ group: GroupReference, inviteCode: String?, reason: String?, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Requests to leave a group.
    @discardableResult
    func leave(
        _ group: GroupReference, reason: String?, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes a content event into a group.
    @discardableResult
    func publishMessage(
        _ content: String,
        kind: Event.Kind,
        in group: GroupReference,
        tags: [Tag],
        previous: [String],
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes a moderation action into a group.
    @discardableResult
    func publishModeration(
        _ action: Groups.ModerationAction,
        in group: GroupReference,
        previous: [String],
        reason: String?,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent

    /// Fetches a group's kind-39000 metadata.
    func fetchMetadata(
        for group: GroupReference, authorPublicKey: PublicKey?, timeout: Duration?
    ) async throws -> Groups.Metadata?
    /// Fetches a group's full relay-generated state snapshot.
    func fetchState(
        for group: GroupReference, authorPublicKey: PublicKey?, timeout: Duration?
    ) async throws -> GroupState
    /// Subscribes to a group's live timeline.
    func timeline(
        _ group: GroupReference, kinds: [Event.Kind]?, since: Timestamp?, limit: Int?
    ) async throws -> SubscriptionSequence

    /// Fetches the kind-10009 list of groups a user is in.
    func fetchSimpleGroupList(for publicKey: PublicKey?, timeout: Duration?) async throws -> SimpleGroupList?
    /// Publishes the current user's kind-10009 group list.
    @discardableResult
    func publishSimpleGroupList(
        _ list: SimpleGroupList, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
}

// MARK: - Lists

/// Reading and writing NIP-51 lists and sets. Implemented by ``NostrListsAPI``.
public protocol NostrListManaging: Sendable {
    /// Publishes a NIP-51 list, replacing the current list of that kind.
    @discardableResult
    func publish(_ list: NostrList, strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Fetches the newest list of a kind.
    func fetch(kind: Event.Kind, for publicKey: PublicKey?, timeout: Duration?) async throws -> NostrList?

    /// Publishes a NIP-51 set, replacing any prior set with the same kind and `d` identifier.
    @discardableResult
    func publishSet(_ set: NostrListSet, strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Fetches one set by kind and `d` identifier.
    func fetchSet(
        kind: Event.Kind, identifier: String, for publicKey: PublicKey?, timeout: Duration?
    ) async throws -> NostrListSet?
    /// Fetches every set of a kind for an author, newest per `d` identifier.
    func fetchSets(kind: Event.Kind, for publicKey: PublicKey?, timeout: Duration?) async throws -> [NostrListSet]
    /// Fetches the set addressed by a NIP-19 `naddr`.
    func fetchSet(naddr: NAddr, timeout: Duration?) async throws -> NostrListSet?
}
