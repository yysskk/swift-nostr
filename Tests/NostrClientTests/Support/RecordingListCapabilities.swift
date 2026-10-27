import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrListsAPI`` that implements only the ``NostrListManaging`` primitives: it
/// records every call, signs each published list or set for real without sending it, and answers
/// fetches with canned values, so the protocol extension can be exercised without a relay pool.
actor RecordingListCapabilities: NostrListManaging {
    struct ListPublish: Sendable {
        let list: NostrList
        let strategy: PublishStrategy?
    }

    struct SetPublish: Sendable {
        let set: NostrListSet
        let strategy: PublishStrategy?
    }

    /// One fetch, list or set; `identifier` is nil for a list fetch and for a fetch of every set.
    struct Fetch: Sendable, Equatable {
        let kind: Event.Kind
        let identifier: String?
        let publicKey: PublicKey?
        let timeout: Duration?
    }

    /// Signs the published lists and sets, encrypting their private items to itself.
    let signer: EventSigner
    /// What every set fetch returns.
    let cannedSet: NostrListSet?

    private(set) var listPublishes: [ListPublish] = []
    private(set) var setPublishes: [SetPublish] = []
    private(set) var listFetches: [Fetch] = []
    private(set) var setFetches: [Fetch] = []
    private(set) var setsFetches: [Fetch] = []

    init(signer: EventSigner, cannedSet: NostrListSet? = nil) {
        self.signer = signer
        self.cannedSet = cannedSet
    }

    // MARK: - NostrListManaging

    func publish(_ list: NostrList, strategy: PublishStrategy?) async throws -> PublishedEvent {
        listPublishes.append(ListPublish(list: list, strategy: strategy))
        let template = try await EventTemplate.list(list, encryptingWith: signer)
        return PublishedEvent(event: try signer.sign(template), result: PublishResult(statuses: [:]))
    }

    func fetch(kind: Event.Kind, for publicKey: PublicKey?, timeout: Duration?) async throws -> NostrList? {
        listFetches.append(Fetch(kind: kind, identifier: nil, publicKey: publicKey, timeout: timeout))
        return NostrList(kind: kind)
    }

    func publishSet(_ set: NostrListSet, strategy: PublishStrategy?) async throws -> PublishedEvent {
        setPublishes.append(SetPublish(set: set, strategy: strategy))
        let template = try await EventTemplate.set(set, encryptingWith: signer)
        return PublishedEvent(event: try signer.sign(template), result: PublishResult(statuses: [:]))
    }

    func fetchSet(
        kind: Event.Kind,
        identifier: String,
        for publicKey: PublicKey?,
        timeout: Duration?
    ) async throws -> NostrListSet? {
        setFetches.append(Fetch(kind: kind, identifier: identifier, publicKey: publicKey, timeout: timeout))
        return cannedSet
    }

    func fetchSets(kind: Event.Kind, for publicKey: PublicKey?, timeout: Duration?) async throws -> [NostrListSet] {
        setsFetches.append(Fetch(kind: kind, identifier: nil, publicKey: publicKey, timeout: timeout))
        return cannedSet.map { [$0] } ?? []
    }
}
