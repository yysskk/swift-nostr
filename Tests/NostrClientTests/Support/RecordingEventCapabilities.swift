import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrEventsAPI`` that implements only the ``NostrEventPublishing`` and
/// ``NostrEventFetching`` primitives: it records every call and answers with canned results, so the
/// protocol extensions can be exercised without a relay pool.
///
/// Targeting mimics a pool holding `pooledRelays`: a targeted call none of whose relays is pooled
/// (an empty set included) throws ``RelayPool/Error/noMatchingRelays(_:)`` after it is recorded.
actor RecordingEventCapabilities: NostrEventPublishing, NostrEventFetching {
    struct TemplatePublish: Sendable {
        let template: EventTemplate
        let relayURLs: Set<RelayURL>?
        let strategy: PublishStrategy?
    }

    struct EventPublish: Sendable {
        let event: Event
        let relayURLs: Set<RelayURL>?
        let strategy: PublishStrategy?
    }

    struct Query: Sendable {
        let filters: [Filter]
        let relayURLs: Set<RelayURL>?
        let timeout: Duration?
    }

    /// Signs the templates handed to the template publish.
    let signer: EventSigner
    /// The relays a targeted call may reach; nil accepts any non-empty target set.
    let pooledRelays: Set<RelayURL>?
    /// What every fetch returns.
    let cannedEvents: [Event]
    /// What every count returns.
    let cannedCount: Int
    /// What every publish reports.
    let cannedResult: PublishResult

    private(set) var templatePublishes: [TemplatePublish] = []
    private(set) var eventPublishes: [EventPublish] = []
    private(set) var fetches: [Query] = []
    private(set) var counts: [Query] = []

    init(
        signer: EventSigner,
        pooledRelays: Set<RelayURL>? = nil,
        cannedEvents: [Event] = [],
        cannedCount: Int = 0,
        cannedResult: PublishResult = PublishResult(statuses: [:])
    ) {
        self.signer = signer
        self.pooledRelays = pooledRelays
        self.cannedEvents = cannedEvents
        self.cannedCount = cannedCount
        self.cannedResult = cannedResult
    }

    // MARK: - NostrEventPublishing

    func publish(
        _ template: EventTemplate,
        to relayURLs: Set<RelayURL>?,
        strategy: PublishStrategy?
    ) async throws -> PublishedEvent {
        templatePublishes.append(TemplatePublish(template: template, relayURLs: relayURLs, strategy: strategy))
        try checkTargets(relayURLs)
        return PublishedEvent(event: try signer.sign(template), result: cannedResult)
    }

    func publish(
        _ event: Event,
        to relayURLs: Set<RelayURL>?,
        strategy: PublishStrategy?
    ) async throws -> PublishResult {
        eventPublishes.append(EventPublish(event: event, relayURLs: relayURLs, strategy: strategy))
        try checkTargets(relayURLs)
        return cannedResult
    }

    // MARK: - NostrEventFetching

    func fetch(filters: [Filter], from relayURLs: Set<RelayURL>?, timeout: Duration?) async throws -> [Event] {
        fetches.append(Query(filters: filters, relayURLs: relayURLs, timeout: timeout))
        try checkTargets(relayURLs)
        return cannedEvents
    }

    func countEvents(
        matching filters: [Filter],
        from relayURLs: Set<RelayURL>?,
        timeout: Duration?
    ) async throws -> Int {
        counts.append(Query(filters: filters, relayURLs: relayURLs, timeout: timeout))
        try checkTargets(relayURLs)
        return cannedCount
    }

    // MARK: - Private

    private func checkTargets(_ relayURLs: Set<RelayURL>?) throws {
        guard let relayURLs else { return }
        let reachable = pooledRelays.map { relayURLs.intersection($0) } ?? relayURLs
        guard !reachable.isEmpty else {
            throw RelayPool.Error.noMatchingRelays(relayURLs.sorted { $0.description < $1.description })
        }
    }
}
