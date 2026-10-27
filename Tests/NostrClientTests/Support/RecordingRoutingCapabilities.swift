import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrRoutingAPI`` that implements only the ``NostrRelayRouting`` primitives: it
/// records every call, signs each published list for real without sending it, answers fetches with
/// canned lists, and opens each outbox subscription as an already-finished sequence, so the protocol
/// extension can be exercised without a relay pool.
actor RecordingRoutingCapabilities: NostrRelayRouting {
    struct Fetch: Sendable, Equatable {
        let publicKey: PublicKey
        let timeout: Duration?
    }

    struct RelayListPublish: Sendable {
        let relayList: RelayListMetadata
        let strategy: PublishStrategy?
    }

    struct DirectMessageRelayListPublish: Sendable {
        let relayList: DirectMessageRelayList
        let strategy: PublishStrategy?
    }

    struct OutboxSubscribe: Sendable, Equatable {
        let authors: [PublicKey]
        let kinds: [Event.Kind]
        let limit: Int?
    }

    struct GossipPublish: Sendable {
        let event: Event
        let strategy: PublishStrategy?
    }

    /// Signs the published lists.
    let signer: EventSigner
    /// What every relay-list fetch returns.
    let cannedRelayList: RelayListMetadata?
    /// What every DM relay-list fetch returns.
    let cannedDirectMessageRelayList: DirectMessageRelayList?

    private(set) var relayListFetches: [Fetch] = []
    private(set) var directMessageRelayListFetches: [Fetch] = []
    private(set) var relayListPublishes: [RelayListPublish] = []
    private(set) var directMessageRelayListPublishes: [DirectMessageRelayListPublish] = []
    private(set) var outboxSubscribes: [OutboxSubscribe] = []
    private(set) var gossipPublishes: [GossipPublish] = []
    private(set) var inboxConnects = 0

    init(
        signer: EventSigner,
        cannedRelayList: RelayListMetadata? = nil,
        cannedDirectMessageRelayList: DirectMessageRelayList? = nil
    ) {
        self.signer = signer
        self.cannedRelayList = cannedRelayList
        self.cannedDirectMessageRelayList = cannedDirectMessageRelayList
    }

    // MARK: - NostrRelayRouting

    func fetchRelayList(for publicKey: PublicKey, timeout: Duration?) async throws -> RelayListMetadata? {
        relayListFetches.append(Fetch(publicKey: publicKey, timeout: timeout))
        return cannedRelayList
    }

    func cachedRelayList(for publicKey: PublicKey) async -> RelayListMetadata? {
        nil
    }

    func publishRelayList(_ relayList: RelayListMetadata, strategy: PublishStrategy?) async throws -> PublishedEvent {
        relayListPublishes.append(RelayListPublish(relayList: relayList, strategy: strategy))
        return PublishedEvent(
            event: signer.sign(.relayListMetadata(relayList)), result: PublishResult(statuses: [:]))
    }

    func subscribeOutbox(authors: [PublicKey], kinds: [Event.Kind], limit: Int?) async throws -> SubscriptionSequence {
        outboxSubscribes.append(OutboxSubscribe(authors: authors, kinds: kinds, limit: limit))
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        continuation.finish()
        return SubscriptionSequence(
            id: "outbox_\(outboxSubscribes.count)", expectedRelays: [], stream: stream, onClose: {})
    }

    func publishGossip(_ event: Event, strategy: PublishStrategy?) async throws -> PublishResult {
        gossipPublishes.append(GossipPublish(event: event, strategy: strategy))
        return PublishResult(statuses: [:])
    }

    func fetchDirectMessageRelayList(
        for publicKey: PublicKey, timeout: Duration?
    ) async throws -> DirectMessageRelayList? {
        directMessageRelayListFetches.append(Fetch(publicKey: publicKey, timeout: timeout))
        return cannedDirectMessageRelayList
    }

    func cachedDirectMessageRelayList(for publicKey: PublicKey) async -> DirectMessageRelayList? {
        nil
    }

    func publishDirectMessageRelayList(
        _ relayList: DirectMessageRelayList,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        directMessageRelayListPublishes.append(DirectMessageRelayListPublish(relayList: relayList, strategy: strategy))
        return PublishedEvent(
            event: signer.sign(.directMessageRelayList(relayList)), result: PublishResult(statuses: [:]))
    }

    func connectDirectMessageInboxRelays() async throws -> Set<RelayURL> {
        inboxConnects += 1
        return Set(cannedDirectMessageRelayList?.relays ?? [])
    }
}
