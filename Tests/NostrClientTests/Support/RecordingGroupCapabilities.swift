import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrGroupsAPI`` that implements only the ``NostrGroupManaging`` primitives: it
/// records every call, signs each published template for real without sending it, and answers reads
/// with empty values, so the protocol extension can be exercised without a relay.
actor RecordingGroupCapabilities: NostrGroupManaging {
    struct Publish: Sendable {
        let template: EventTemplate
        let group: GroupReference
        let strategy: PublishStrategy?
    }

    /// One metadata or state fetch.
    struct StateFetch: Sendable, Equatable {
        let group: GroupReference
        let authorPublicKey: PublicKey?
        let timeout: Duration?
    }

    struct Timeline: Sendable, Equatable {
        let group: GroupReference
        let kinds: [Event.Kind]?
        let since: Timestamp?
        let limit: Int?
    }

    struct ListFetch: Sendable, Equatable {
        let publicKey: PublicKey?
        let timeout: Duration?
    }

    struct ListPublish: Sendable {
        let list: SimpleGroupList
        let strategy: PublishStrategy?
    }

    /// Signs the published templates.
    let signer: EventSigner

    private(set) var publishes: [Publish] = []
    private(set) var metadataFetches: [StateFetch] = []
    private(set) var stateFetches: [StateFetch] = []
    private(set) var timelines: [Timeline] = []
    private(set) var listFetches: [ListFetch] = []
    private(set) var listPublishes: [ListPublish] = []

    init(signer: EventSigner) {
        self.signer = signer
    }

    // MARK: - NostrGroupManaging

    func publish(_ template: EventTemplate, in group: GroupReference, strategy: PublishStrategy?) async throws
        -> PublishedEvent
    {
        publishes.append(Publish(template: template, group: group, strategy: strategy))
        return PublishedEvent(event: try signer.sign(template), result: PublishResult(statuses: [:]))
    }

    func fetchMetadata(
        for group: GroupReference,
        authorPublicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> Groups.Metadata? {
        metadataFetches.append(StateFetch(group: group, authorPublicKey: authorPublicKey, timeout: timeout))
        return Groups.Metadata(groupID: group.id)
    }

    func fetchState(
        for group: GroupReference,
        authorPublicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> GroupState {
        stateFetches.append(StateFetch(group: group, authorPublicKey: authorPublicKey, timeout: timeout))
        return GroupState()
    }

    func timeline(
        _ group: GroupReference,
        kinds: [Event.Kind]?,
        since: Timestamp?,
        limit: Int?
    ) async throws -> SubscriptionSequence {
        timelines.append(Timeline(group: group, kinds: kinds, since: since, limit: limit))
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        continuation.finish()
        return SubscriptionSequence(
            id: "timeline_\(timelines.count)", expectedRelays: [group.relayURL], stream: stream, onClose: {})
    }

    func fetchSimpleGroupList(for publicKey: PublicKey?, timeout: Duration?) async throws -> SimpleGroupList? {
        listFetches.append(ListFetch(publicKey: publicKey, timeout: timeout))
        return SimpleGroupList()
    }

    func publishSimpleGroupList(_ list: SimpleGroupList, strategy: PublishStrategy?) async throws -> PublishedEvent {
        listPublishes.append(ListPublish(list: list, strategy: strategy))
        let template = try await EventTemplate.list(list.list, encryptingWith: signer)
        return PublishedEvent(event: try signer.sign(template), result: PublishResult(statuses: [:]))
    }
}
