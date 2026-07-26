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
// Swift does not allow default argument values on protocol requirements, so the requirements
// below spell out every parameter. The concrete namespaces still supply the defaults, so a call
// through `client.messages` stays short; only a call through the protocol passes the full
// argument list.

// MARK: - Identity

/// Managing the signer the client authors events with, and proving it to relays (NIP-42).
/// Implemented by ``NostrIdentityAPI``.
public protocol NostrIdentityProviding: Sendable {
    /// Sets a local signer.
    func setSigner(_ signer: EventSigner) async
    /// Sets a local or remote (NIP-46) signer.
    func setSigner(_ signer: any NostrSigning) async throws
    /// Sets a local signer from a private key hex string.
    func setPrivateKey(_ privateKeyHex: String) async throws
    /// Sets a local signer from an nsec.
    func setNsec(_ nsec: String) async throws

    /// The public key events are authored under, or nil when no signer is set.
    var publicKey: String? { get async }
    /// The signer's public key as an npub, or nil when no signer is set.
    var npub: String? { get async throws }

    /// Signs an event with the configured signer.
    func sign(_ unsignedEvent: UnsignedEvent) async throws -> Event

    /// How the client reacts to relay AUTH challenges.
    var authenticationMode: AuthenticationMode { get async }
    /// Sets how the client reacts to relay AUTH challenges.
    func setAuthenticationMode(_ mode: AuthenticationMode) async
    /// Answers one relay's pending AUTH challenge.
    func authenticate(relayURL: URL) async throws
}

// MARK: - Relays

/// Managing which relays the client talks to and whether they are connected.
/// Implemented by ``NostrRelaysAPI``.
///
/// Deliberately does not vend the underlying ``RelayPool``: handing it over would give a
/// relay-management dependency the pool's publish, subscribe, and count as well, and would force
/// every stub to stand up a real pool. Take ``NostrRelaysAPI`` concretely when you need
/// ``NostrRelaysAPI/pool``.
public protocol NostrRelayManaging: Sendable {
    /// Adds a relay, optionally with a per-relay connection configuration.
    @discardableResult
    func add(_ urlString: String, config: RelayConnectionConfig?) async throws -> RelayConnection
    /// Adds multiple relays.
    func add(_ urlStrings: [String]) async throws
    /// Removes a relay from the pool, disconnecting it.
    func remove(_ urlString: String) async throws

    /// Connects to all relays in the pool.
    func connect() async throws
    /// Adds the given relays, then connects to all relays in the pool.
    func connect(to urlStrings: [String]) async throws
    /// Disconnects from all relays.
    func disconnect() async

    /// Every relay connection in the pool, in no guaranteed order.
    var connections: [RelayConnection] { get async }
    /// The number of relays in the pool, connected or not.
    var count: Int { get async }
    /// The number of relays currently connected.
    func connectedCount() async -> Int
    /// The pool's connection for a relay URL, or nil when it is not in the pool.
    func relay(for url: URL) async -> RelayConnection?
    /// Clears every subscription's event deduplication cache in the relay pool.
    func clearDeduplicationCache() async
}

// MARK: - Events

/// Authoring and publishing events. Implemented by ``NostrEventsAPI``.
public protocol NostrEventPublishing: Sendable {
    /// Publishes a text note.
    @discardableResult
    func publishTextNote(content: String, tags: [Tag], strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Publishes a NIP-10 reply.
    @discardableResult
    func publishReply(
        to event: Event, content: String, relayURL: String?, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes user metadata.
    @discardableResult
    func publishMetadata(_ metadata: UserMetadata, strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Publishes a reaction.
    @discardableResult
    func publishReaction(to event: Event, content: String, strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Publishes a repost.
    @discardableResult
    func publishRepost(
        of event: Event, relayURL: String?, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes a deletion request.
    @discardableResult
    func publishDeletion(
        eventIds: [String], reason: String, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes a NIP-56 report of a pubkey.
    @discardableResult
    func publishReport(
        pubkey: String, type: ReportType, reason: String, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes a NIP-56 report of an event.
    @discardableResult
    func publishReport(
        event: Event, type: ReportType, reason: String, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes an already-signed event.
    @discardableResult
    func publish(_ event: Event, strategy: PublishStrategy?) async throws -> PublishResult

    /// Publishes a NIP-23 long-form article or draft.
    @discardableResult
    func publishLongFormContent(
        _ article: LongFormContent, draft: Bool, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
}

/// Reading stored events one time, without holding a subscription open.
/// Implemented by ``NostrEventsAPI``.
public protocol NostrEventFetching: Sendable {
    /// Fetches events matching `filters`, ending at EOSE or `timeout`.
    func fetch(filters: [Filter], to relayURLs: [String]?, timeout: TimeInterval) async throws -> [Event]
    /// Requests the NIP-45 count of events matching `filters`.
    func count(filters: [Filter], to relayURLs: [String]?, timeout: TimeInterval) async throws -> Int
    /// Fetches a single event by id.
    func fetchEvent(id: String, timeout: TimeInterval) async throws -> Event?
    /// Fetches a user's metadata.
    func fetchMetadata(pubkey: String, timeout: TimeInterval) async throws -> UserMetadata?
    /// Fetches a NIP-23 article by author and identifier.
    func fetchLongFormContent(
        author: String, identifier: String, timeout: TimeInterval
    ) async throws -> LongFormContent?
    /// Fetches the NIP-23 article addressed by an `naddr`.
    func fetchLongFormContent(naddr: NAddr, timeout: TimeInterval) async throws -> LongFormContent?
}

// MARK: - Subscriptions

/// Opening live subscriptions. Implemented by ``NostrSubscriptionsAPI``.
public protocol NostrSubscribing: Sendable {
    /// Opens a subscription as a sequence of relay-aware events.
    func subscribe(
        filters: [Filter],
        to relayURLs: [String]?,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    ) async throws -> SubscriptionSequence
    /// Opens a subscription as a sequence of event payloads only.
    func events(
        filters: [Filter],
        to relayURLs: [String]?,
        bufferingPolicy: AsyncStream<SubscriptionEvent>.Continuation.BufferingPolicy
    ) async throws -> SubscriptionSequence.Events
    /// Closes one subscription.
    func unsubscribe(subscriptionId: String) async
    /// Closes every open subscription.
    func unsubscribeAll() async

    /// Subscribes to a user's timeline.
    func userTimeline(pubkey: String, limit: Int) async throws -> SubscriptionSequence
    /// Subscribes to the global feed.
    func globalFeed(limit: Int) async throws -> SubscriptionSequence
    /// Subscribes to mentions of a user.
    func mentions(pubkey: String, limit: Int) async throws -> SubscriptionSequence
    /// Subscribes to metadata updates for a list of pubkeys.
    func metadata(pubkeys: [String]) async throws -> SubscriptionSequence
}

// MARK: - Routing

/// Discovering where a user's events live (NIP-65) and where their messages go (NIP-17),
/// and routing by those lists. Implemented by ``NostrRoutingAPI``.
public protocol NostrRelayRouting: Sendable {
    /// Fetches and caches a user's NIP-65 relay list.
    func fetchRelayList(for pubkey: String, timeout: TimeInterval) async throws -> RelayListMetadata?
    /// The cached NIP-65 relay list for a pubkey, without a network fetch.
    func cachedRelayList(for pubkey: String) async -> RelayListMetadata?
    /// Publishes the current user's NIP-65 relay list.
    @discardableResult
    func publishRelayList(
        _ relayList: RelayListMetadata, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes the current user's NIP-65 relay list from read/write URLs.
    @discardableResult
    func publishRelayList(
        read: [String], write: [String], strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Subscribes to authors on their own WRITE relays (the outbox model).
    func subscribeOutbox(
        authors: [String], kinds: [Event.Kind], limit: Int?
    ) async throws -> SubscriptionSequence
    /// Publishes a signed event to the author's WRITE relays and its mentions' READ relays.
    @discardableResult
    func publishGossip(_ event: Event, strategy: PublishStrategy?) async throws -> PublishResult

    /// Fetches and caches a user's NIP-17 DM relay list.
    func fetchDirectMessageRelayList(
        for pubkey: String, timeout: TimeInterval
    ) async throws -> DirectMessageRelayList?
    /// The cached NIP-17 DM relay list for a pubkey, without a network fetch.
    func cachedDirectMessageRelayList(for pubkey: String) async -> DirectMessageRelayList?
    /// Publishes the current user's NIP-17 DM relay list.
    @discardableResult
    func publishDirectMessageRelayList(
        _ relayList: DirectMessageRelayList, strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Publishes the current user's NIP-17 DM relay list from relay URLs.
    @discardableResult
    func publishDirectMessageRelayList(
        relays: [String], strategy: PublishStrategy?
    ) async throws -> PublishedEvent
    /// Connects the current user's own DM inbox relays so messages sent there arrive.
    @discardableResult
    func connectDirectMessageInboxRelays() async throws -> Set<URL>
}

// MARK: - Messages

/// Sending and receiving NIP-17 private direct messages. Implemented by ``NostrMessagesAPI``.
public protocol NostrMessaging: Sendable {
    /// Sends a private direct message.
    @discardableResult
    func send(
        _ content: String,
        to recipientPubkey: String,
        subject: String?,
        replyTo: String?,
        expiration: Date?,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult
    /// Sends a NIP-25 reaction to a received message.
    @discardableResult
    func react(
        to message: DirectMessage, reaction: String, expiration: Date?, strategy: PublishStrategy?
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
        to recipientPubkey: String,
        expiration: Date?,
        strategy: PublishStrategy?
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
        for group: GroupReference, authorPubkey: String?, timeout: TimeInterval
    ) async throws -> Groups.Metadata?
    /// Fetches a group's full relay-generated state snapshot.
    func fetchState(
        for group: GroupReference, authorPubkey: String?, timeout: TimeInterval
    ) async throws -> GroupState
    /// Subscribes to a group's live timeline.
    func timeline(
        _ group: GroupReference, kinds: [Event.Kind]?, since: Date?, limit: Int?
    ) async throws -> SubscriptionSequence

    /// Fetches the kind-10009 list of groups a user is in.
    func fetchSimpleGroupList(for pubkey: String?, timeout: TimeInterval) async throws -> SimpleGroupList?
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
    func fetch(kind: Event.Kind, for pubkey: String?, timeout: TimeInterval) async throws -> NostrList?

    /// Publishes a NIP-51 set, replacing any prior set with the same kind and `d` identifier.
    @discardableResult
    func publishSet(_ set: NostrListSet, strategy: PublishStrategy?) async throws -> PublishedEvent
    /// Fetches one set by kind and `d` identifier.
    func fetchSet(
        kind: Event.Kind, identifier: String, for pubkey: String?, timeout: TimeInterval
    ) async throws -> NostrListSet?
    /// Fetches every set of a kind for an author, newest per `d` identifier.
    func fetchSets(kind: Event.Kind, for pubkey: String?, timeout: TimeInterval) async throws -> [NostrListSet]
    /// Fetches the set addressed by a NIP-19 `naddr`.
    func fetchSet(naddr: NAddr, timeout: TimeInterval) async throws -> NostrListSet?
}
