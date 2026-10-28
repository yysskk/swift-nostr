import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrEventPublishing`` and ``NostrEventFetching`` conveniences are written once, in protocol
/// extensions over the primitives. Driving them through a stub that implements only the primitives
/// shows what each one builds and forwards — template, route, strategy, filters, timeout, and the
/// defaults — without a relay pool.
@Suite("Event Capability Tests")
struct EventCapabilityTests {
    private let relayA = RelayURL("wss://a.example.com")!
    private let relayB = RelayURL("wss://b.example.com")!

    private func makeStub(
        pooledRelays: Set<RelayURL>? = nil,
        cannedEvents: [Event] = [],
        cannedCount: Int = 0
    ) throws -> RecordingEventCapabilities {
        RecordingEventCapabilities(
            signer: EventSigner(keyPair: KeyPair()),
            pooledRelays: pooledRelays,
            cannedEvents: cannedEvents,
            cannedCount: cannedCount,
            cannedResult: PublishResult(statuses: [relayA: .accepted])
        )
    }

    private func note(_ content: String = "parent") throws -> Event {
        EventSigner(keyPair: KeyPair()).sign(.textNote(content))
    }

    /// `event` with its content altered but its id and signature kept — a copy that no longer verifies.
    private func tampered(_ event: Event) -> Event {
        Event(
            id: event.id, publicKey: event.publicKey, createdAt: event.createdAt, kind: event.kind,
            tags: event.tags, content: "tampered", signature: event.signature)
    }

    /// The one template publish the stub recorded.
    private func onlyTemplatePublish(
        _ stub: RecordingEventCapabilities
    ) async throws -> RecordingEventCapabilities.TemplatePublish {
        let publishes = await stub.templatePublishes
        #expect(publishes.count == 1)
        #expect(await stub.eventPublishes.isEmpty)
        return try #require(publishes.first)
    }

    /// The one fetch the stub recorded.
    private func onlyFetch(_ stub: RecordingEventCapabilities) async throws -> RecordingEventCapabilities.Query {
        let fetches = await stub.fetches
        #expect(fetches.count == 1)
        return try #require(fetches.first)
    }

    // MARK: - Publish primitives' short forms

    @Test("publishing a template without a route signs it and sends it to the whole pool")
    func templatePublishShortFormDefaultsToPool() async throws {
        let stub = try makeStub()
        let publishing: any NostrEventPublishing = stub

        let published = try await publishing.publish(.textNote("templated"))

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.content == "templated")
        #expect(recorded.route == .pool)
        #expect(recorded.strategy == nil)
        #expect(published.event.content == "templated")
        #expect(published.event.publicKey == stub.signer.publicKey)
        #expect(published.result.acceptedRelays == [relayA])
    }

    @Test("publishing a template along a route forwards it with no strategy")
    func templatePublishShortFormForwardsRoute() async throws {
        let stub = try makeStub()
        let publishing: any NostrEventPublishing = stub

        try await publishing.publish(.textNote("targeted"), route: .relays([relayA, relayB]))
        try await publishing.publish(.textNote("gossip"), route: .outbox)

        let recorded = await stub.templatePublishes
        #expect(recorded.map(\.route) == [.relays([relayA, relayB]), .outbox])
        #expect(recorded.map(\.strategy) == [nil, nil])
    }

    @Test("publishing a signed event without a route sends it to the whole pool")
    func eventPublishShortFormDefaultsToPool() async throws {
        let stub = try makeStub()
        let publishing: any NostrEventPublishing = stub
        let event = try note()

        let result = try await publishing.publish(event)

        let recorded = try #require(await stub.eventPublishes.first)
        #expect(await stub.eventPublishes.count == 1)
        #expect(recorded.event == event)
        #expect(recorded.route == .pool)
        #expect(recorded.strategy == nil)
        #expect(result.acceptedRelays == [relayA])
    }

    @Test("publishing a signed event along a route forwards it, an empty relay set included")
    func eventPublishShortFormForwardsRoute() async throws {
        let stub = try makeStub()
        let publishing: any NostrEventPublishing = stub
        let event = try note()

        try await publishing.publish(event, route: .relays([relayB]))
        try await publishing.publish(event, route: .outbox)
        // An empty set stays a `.relays` route — it reaches the primitive, which rejects it, rather
        // than collapsing to the whole pool.
        await #expect(throws: RelayPool.Error.noMatchingRelays([])) {
            try await publishing.publish(event, route: .relays([]))
        }

        let recorded = await stub.eventPublishes
        #expect(recorded.map(\.route) == [.relays([relayB]), .outbox, .relays([])])
        #expect(recorded.map(\.strategy) == [nil, nil, nil])
    }

    // MARK: - Publish conveniences

    @Test("publishTextNote builds a kind-1 note with no tags and the default strategy by default")
    func publishTextNoteDefaults() async throws {
        let stub = try makeStub()

        let published = try await stub.publishTextNote(content: "gm")

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.kind == .textNote)
        #expect(recorded.template.content == "gm")
        #expect(recorded.template.tags.isEmpty)
        #expect(recorded.route == .pool)
        #expect(recorded.strategy == nil)
        #expect(published.event.content == "gm")
    }

    @Test("publishTextNote forwards its tags and strategy")
    func publishTextNoteForwardsArguments() async throws {
        let stub = try makeStub()

        try await stub.publishTextNote(content: "gm", tags: [.hashtag("nostr")], strategy: .allSettled)

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.tags == [.hashtag("nostr")])
        #expect(recorded.strategy == .allSettled)
    }

    @Test("publishReply threads the reply with EventTemplate.reply")
    func publishReplyBuildsTheNIP10Template() async throws {
        let stub = try makeStub()
        let parent = try note()

        try await stub.publishReply(to: parent, content: "a reply")
        try await stub.publishReply(to: parent, content: "hinted", relayURL: relayB, strategy: .firstAck)

        let recorded = await stub.templatePublishes
        #expect(recorded.count == 2)
        #expect(recorded[0].template.kind == .textNote)
        #expect(recorded[0].template.content == "a reply")
        #expect(recorded[0].template.tags == EventTemplate.reply(to: parent, content: "a reply").tags)
        #expect(
            recorded[0].template.tags.map(\.rawArray) == [
                ["e", parent.id.hex, "", "root"], ["p", parent.publicKey.hex],
            ])
        #expect(recorded[0].route == .pool)
        #expect(recorded[0].strategy == nil)
        #expect(recorded[1].template.tags.first?.rawArray == ["e", parent.id.hex, "wss://b.example.com", "root"])
        #expect(recorded[1].strategy == .firstAck)
    }

    @Test("publishMetadata builds a kind-0 profile")
    func publishMetadata() async throws {
        let stub = try makeStub()
        let profile = UserMetadata(name: "Alice", about: "Nostr user")

        try await stub.publishMetadata(profile, strategy: .allSettled)

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.kind == .setMetadata)
        let decoded = try JSONDecoder().decode(UserMetadata.self, from: Data(recorded.template.content.utf8))
        #expect(decoded.name == "Alice")
        #expect(decoded.about == "Nostr user")
        #expect(recorded.route == .pool)
        #expect(recorded.strategy == .allSettled)
    }

    @Test("publishReaction likes by default and forwards a custom reaction")
    func publishReaction() async throws {
        let stub = try makeStub()
        let target = try note()

        try await stub.publishReaction(to: target)
        try await stub.publishReaction(to: target, content: "🤙", strategy: .allSettled)

        let recorded = await stub.templatePublishes
        #expect(recorded.map(\.template.kind) == [.reaction, .reaction])
        #expect(recorded.map(\.template.content) == ["+", "🤙"])
        #expect(recorded[0].template.tags.map(\.rawArray) == [["e", target.id.hex], ["p", target.publicKey.hex]])
        #expect(recorded.map(\.strategy) == [nil, .allSettled])
    }

    @Test("publishRepost embeds the event and records the relay only when given")
    func publishRepost() async throws {
        let stub = try makeStub()
        let target = try note()

        try await stub.publishRepost(of: target)
        try await stub.publishRepost(of: target, relayURL: relayA)

        let recorded = await stub.templatePublishes
        #expect(recorded.map(\.template.kind) == [.repost, .repost])
        #expect(recorded[0].template.tags.first?.rawArray == ["e", target.id.hex])
        #expect(recorded[1].template.tags.first?.rawArray == ["e", target.id.hex, "wss://a.example.com"])
        #expect(try JSONDecoder().decode(Event.self, from: Data(recorded[0].template.content.utf8)) == target)
        #expect(recorded.allSatisfy { $0.route == .pool && $0.strategy == nil })
    }

    @Test("publishDeletion writes one e tag per id with an empty reason by default")
    func publishDeletion() async throws {
        let stub = try makeStub()

        try await stub.publishDeletion(eventIDs: [.fixture("first"), .fixture("second")])
        try await stub.publishDeletion(eventIDs: [.fixture("first")], reason: "oops", strategy: .allSettled)

        let recorded = await stub.templatePublishes
        #expect(recorded.map(\.template.kind) == [.eventDeletion, .eventDeletion])
        #expect(
            recorded[0].template.tags.map(\.rawArray) == [
                ["e", EventID.fixture("first").hex], ["e", EventID.fixture("second").hex],
            ])
        #expect(recorded.map(\.template.content) == ["", "oops"])
        #expect(recorded.map(\.strategy) == [nil, .allSettled])
    }

    @Test("publishReport of a public key puts the type on the p tag, with an empty reason by default")
    func publishReportOfPublicKey() async throws {
        let stub = try makeStub()

        try await stub.publishReport(publicKey: .fixture("spammer"), type: .spam)

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.kind == .report)
        #expect(recorded.template.tags.map(\.rawArray) == [["p", PublicKey.fixture("spammer").hex, "spam"]])
        #expect(recorded.template.content.isEmpty)
        #expect(recorded.strategy == nil)
    }

    @Test("publishReport of an event puts the type on the e tag and names its author")
    func publishReportOfEvent() async throws {
        let stub = try makeStub()
        let target = try note()

        try await stub.publishReport(event: target, type: .illegal, reason: "unlawful", strategy: .allSettled)

        let recorded = try await onlyTemplatePublish(stub)
        #expect(recorded.template.kind == .report)
        #expect(
            recorded.template.tags.map(\.rawArray) == [
                ["e", target.id.hex, "illegal"], ["p", target.publicKey.hex],
            ])
        #expect(recorded.template.content == "unlawful")
        #expect(recorded.strategy == .allSettled)
    }

    @Test("publishLongFormContent publishes an article by default and a draft on request")
    func publishLongFormContent() async throws {
        let stub = try makeStub()
        let article = LongFormContent(
            identifier: "essay", title: "Essay", publishedAt: Timestamp(rawValue: 1_700_000_000), content: "Body")

        try await stub.publishLongFormContent(article)
        try await stub.publishLongFormContent(article, draft: true, strategy: .allSettled)

        let recorded = await stub.templatePublishes
        #expect(recorded.map(\.template.kind) == [.longFormContent, .longFormDraft])
        #expect(recorded[0].template.tags == EventTemplate.longFormContent(article).tags)
        #expect(recorded[0].template.content == "Body")
        #expect(recorded.map(\.strategy) == [nil, .allSettled])
        #expect(recorded.allSatisfy { $0.route == .pool })
    }

    // MARK: - Fetch primitives' short forms

    @Test("fetching without a route queries the whole pool with the default timeout")
    func fetchShortFormDefaultsToPool() async throws {
        let event = try note("stored")
        let stub = try makeStub(cannedEvents: [event])
        let fetching: any NostrEventFetching = stub
        let filter = Filter(kinds: [.textNote], limit: 5)

        let events = try await fetching.fetch(filters: [filter])

        let recorded = try await onlyFetch(stub)
        #expect(recorded.filters == [filter])
        #expect(recorded.route == .pool)
        #expect(recorded.timeout == nil)
        #expect(events == [event])
    }

    @Test("fetching along a route forwards it with the default timeout")
    func fetchShortFormForwardsRoute() async throws {
        let stub = try makeStub()
        let fetching: any NostrEventFetching = stub
        let filter = Filter(authors: [PublicKey.fixture("author")], kinds: [.textNote])

        _ = try await fetching.fetch(filters: [filter], route: .relays([relayA]))
        _ = try await fetching.fetch(filters: [filter], route: .outbox)

        let recorded = await stub.fetches
        #expect(recorded.map(\.route) == [.relays([relayA]), .outbox])
        #expect(recorded.map(\.timeout) == [nil, nil])
    }

    @Test("counting forwards the whole pool by default or the given route, with the default timeout")
    func countShortForm() async throws {
        let stub = try makeStub(cannedCount: 42)
        let fetching: any NostrEventFetching = stub
        let filter = Filter(kinds: [.textNote])

        let total = try await fetching.countEvents(matching: [filter])
        let scoped = try await fetching.countEvents(matching: [filter], route: .relays([relayB]))

        let recorded = await stub.counts
        #expect(total == 42 && scoped == 42)
        #expect(recorded.map(\.filters) == [[filter], [filter]])
        #expect(recorded.map(\.route) == [.pool, .relays([relayB])])
        #expect(recorded.map(\.timeout) == [nil, nil])
    }

    // MARK: - Fetch conveniences

    @Test("fetchEvent asks the whole pool for the id and returns only that event, verified")
    func fetchEventSelectsTheRequestedVerifiedEvent() async throws {
        let wanted = try note("wanted")
        let other = try note("other")
        let tampered = tampered(wanted)
        let stub = try makeStub(cannedEvents: [other, tampered, wanted])

        let fetched = try await stub.fetchEvent(id: wanted.id, timeout: .seconds(2))

        let recorded = try await onlyFetch(stub)
        #expect(recorded.filters == [Filter(ids: [wanted.id])])
        #expect(recorded.route == .pool)
        #expect(recorded.timeout == .seconds(2))
        #expect(fetched == wanted)
    }

    @Test("fetchEvent returns nil when no copy of the event verifies")
    func fetchEventRejectsUnverifiedCopies() async throws {
        let wanted = try note("wanted")
        let tampered = tampered(wanted)
        let stub = try makeStub(cannedEvents: [tampered])

        #expect(try await stub.fetchEvent(id: wanted.id) == nil)
        #expect(try await onlyFetch(stub).timeout == nil)
    }

    @Test("fetchMetadata keeps the newest profile the named key signed")
    func fetchMetadataSelectsTheNewestOwnProfile() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let stranger = EventSigner(keyPair: KeyPair())
        var older = try EventTemplate.metadata(UserMetadata(name: "Old"))
        older.createdAt = Timestamp(rawValue: 1_700_000_000)
        var newer = try EventTemplate.metadata(UserMetadata(name: "New"))
        newer.createdAt = Timestamp(rawValue: 1_700_000_100)
        var impostor = try EventTemplate.metadata(UserMetadata(name: "Impostor"))
        impostor.createdAt = Timestamp(rawValue: 1_800_000_000)
        let stub = try makeStub(cannedEvents: [
            author.sign(older), stranger.sign(impostor), author.sign(newer),
        ])

        let metadata = try await stub.fetchMetadata(for: author.publicKey)

        let recorded = try await onlyFetch(stub)
        #expect(recorded.filters == [.metadata(publicKeys: [author.publicKey])])
        #expect(recorded.route == .pool)
        #expect(recorded.timeout == nil)
        #expect(metadata?.name == "New")
    }

    @Test("fetchLongFormContent by author and identifier filters on both and keeps the matching article")
    func fetchLongFormContentByAuthor() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let wanted = author.sign(.longFormContent(LongFormContent(identifier: "essay", title: "Wanted")))
        let otherIdentifier = author.sign(
            .longFormContent(LongFormContent(identifier: "other", title: "Other")))
        let stub = try makeStub(cannedEvents: [otherIdentifier, wanted])

        let article = try await stub.fetchLongFormContent(
            author: author.publicKey, identifier: "essay", timeout: .seconds(4))

        var expected = Filter(authors: [author.publicKey], kinds: [.longFormContent])
        expected[tag: "d"] = ["essay"]
        let recorded = try await onlyFetch(stub)
        #expect(recorded.filters == [expected])
        #expect(recorded.route == .pool)
        #expect(recorded.timeout == .seconds(4))
        #expect(article?.title == "Wanted")
    }

    @Test("fetchLongFormContent(naddr:) queries the coordinate's relay hints when the pool has one")
    func fetchByNAddrUsesPooledHints() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let article = LongFormContent(identifier: "essay", title: "Hinted")
        let stored = author.sign(.longFormContent(article))
        let stub = try makeStub(pooledRelays: [relayA], cannedEvents: [stored])
        let naddr = try article.naddr(author: author.publicKey, relays: [relayA, relayB])

        let fetched = try await stub.fetchLongFormContent(naddr: naddr)

        // The whole hint set goes to the primitive, which skips the hint not in the pool.
        var expected = Filter(authors: [author.publicKey], kinds: [.longFormContent])
        expected[tag: "d"] = ["essay"]
        let recorded = try await onlyFetch(stub)
        #expect(recorded.filters == [expected])
        #expect(recorded.route == .relays([relayA, relayB]))
        #expect(recorded.timeout == nil)
        #expect(fetched?.title == "Hinted")
    }

    @Test("fetchLongFormContent(naddr:) falls back to the whole pool when no hint is in it")
    func fetchByNAddrFallsBackWhenNoHintIsPooled() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let article = LongFormContent(identifier: "essay", title: "Fallback")
        let stored = author.sign(.longFormContent(article))
        let stub = try makeStub(pooledRelays: [relayA], cannedEvents: [stored])
        let naddr = try article.naddr(author: author.publicKey, relays: [relayB])

        let fetched = try await stub.fetchLongFormContent(naddr: naddr, timeout: .seconds(2))

        let recorded = await stub.fetches
        #expect(recorded.map(\.route) == [.relays([relayB]), .pool])
        #expect(recorded.map(\.timeout) == [.seconds(2), .seconds(2)])
        #expect(recorded[0].filters == recorded[1].filters)
        #expect(fetched?.title == "Fallback")
    }

    @Test("fetchLongFormContent(naddr:) without hints queries the whole pool")
    func fetchByNAddrWithoutHintsBroadcasts() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let article = LongFormContent(identifier: "essay", title: "Unhinted")
        // A draft under the same identifier is another kind, so the coordinate does not select it.
        let draft = author.sign(
            .longFormContent(LongFormContent(identifier: "essay", title: "Draft"), draft: true))
        let stub = try makeStub(cannedEvents: [draft, author.sign(.longFormContent(article))])
        let naddr = try article.naddr(author: author.publicKey)

        let fetched = try await stub.fetchLongFormContent(naddr: naddr)

        let recorded = try await onlyFetch(stub)
        #expect(recorded.route == .pool)
        #expect(fetched?.title == "Unhinted")
    }
}
