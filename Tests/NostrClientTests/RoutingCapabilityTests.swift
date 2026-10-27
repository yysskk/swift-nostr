import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrRelayRouting`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows which list
/// each one builds and what it forwards — public key, timeout, kinds, limit, strategy, and the
/// defaults — without a relay pool.
@Suite("Routing Capability Tests")
struct RoutingCapabilityTests {
    private let readRelay = RelayURL("wss://read.example.com")!
    private let writeRelay = RelayURL("wss://write.example.com")!
    private let inboxRelay = RelayURL("wss://inbox.example.com")!
    private let signer: EventSigner

    init() throws {
        signer = EventSigner(keyPair: try KeyPair())
    }

    // MARK: - Short forms of the primitives

    @Test("fetchRelayList(for:) forwards the public key with no timeout")
    func fetchRelayListShortForm() async throws {
        let list = RelayListMetadata(read: [readRelay], write: [writeRelay])
        let stub = RecordingRoutingCapabilities(signer: signer, cannedRelayList: list)
        let routing: any NostrRelayRouting = stub
        let user = PublicKey.fixture("user")

        let fetched = try await routing.fetchRelayList(for: user)

        #expect(fetched == list)
        #expect(await stub.relayListFetches == [.init(publicKey: user, timeout: nil)])
    }

    @Test("fetchDirectMessageRelayList(for:) forwards the public key with no timeout")
    func fetchDirectMessageRelayListShortForm() async throws {
        let list = DirectMessageRelayList(relays: [inboxRelay])
        let stub = RecordingRoutingCapabilities(signer: signer, cannedDirectMessageRelayList: list)
        let routing: any NostrRelayRouting = stub
        let user = PublicKey.fixture("user")

        let fetched = try await routing.fetchDirectMessageRelayList(for: user)

        #expect(fetched == list)
        #expect(await stub.directMessageRelayListFetches == [.init(publicKey: user, timeout: nil)])
    }

    @Test("the publish short forms forward the list with no strategy")
    func publishShortForms() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub
        let relayList = RelayListMetadata(read: [readRelay], write: [writeRelay])
        let dmRelayList = DirectMessageRelayList(relays: [inboxRelay])
        let note = try signer.sign(.textNote("gossip"))

        let relayListEvent = try await routing.publishRelayList(relayList)
        let dmRelayListEvent = try await routing.publishDirectMessageRelayList(dmRelayList)
        try await routing.publishGossip(note)

        let relayListPublishes = await stub.relayListPublishes
        #expect(relayListPublishes.map(\.relayList) == [relayList])
        #expect(relayListPublishes.map(\.strategy) == [nil])
        #expect(relayListEvent.event.kind == .relayListMetadata)

        let dmRelayListPublishes = await stub.directMessageRelayListPublishes
        #expect(dmRelayListPublishes.map(\.relayList) == [dmRelayList])
        #expect(dmRelayListPublishes.map(\.strategy) == [nil])
        #expect(dmRelayListEvent.event.kind == .directMessageRelayList)

        let gossipPublishes = await stub.gossipPublishes
        #expect(gossipPublishes.map(\.event) == [note])
        #expect(gossipPublishes.map(\.strategy) == [nil])
    }

    @Test("subscribeOutbox defaults to text notes with no limit")
    func subscribeOutboxDefaults() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub
        let authors = [PublicKey.fixture("a"), PublicKey.fixture("b")]

        _ = try await routing.subscribeOutbox(authors: authors)
        _ = try await routing.subscribeOutbox(authors: authors, kinds: [.longFormContent])

        #expect(
            await stub.outboxSubscribes == [
                .init(authors: authors, kinds: [.textNote], limit: nil),
                .init(authors: authors, kinds: [.longFormContent], limit: nil),
            ])
    }

    @Test("subscribeOutbox with a limit forwards it, with or without kinds")
    func subscribeOutboxWithLimit() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub
        let authors = [PublicKey.fixture("a")]

        _ = try await routing.subscribeOutbox(authors: authors, limit: 20)
        _ = try await routing.subscribeOutbox(authors: authors, kinds: [.reaction], limit: 5)

        #expect(
            await stub.outboxSubscribes == [
                .init(authors: authors, kinds: [.textNote], limit: 20),
                .init(authors: authors, kinds: [.reaction], limit: 5),
            ])
    }

    // MARK: - Conveniences

    @Test("publishRelayList(read:write:) builds the NIP-65 list and forwards the strategy")
    func publishRelayListFromURLs() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub
        let both = RelayURL("wss://both.example.com")!

        let published = try await routing.publishRelayList(
            read: [readRelay, both], write: [writeRelay, both], strategy: .firstAck)

        let recorded = try #require(await stub.relayListPublishes.first)
        #expect(recorded.relayList == RelayListMetadata(read: [readRelay, both], write: [writeRelay, both]))
        #expect(recorded.strategy == .firstAck)
        #expect(Set(recorded.relayList.readRelays) == [readRelay, both])
        #expect(Set(recorded.relayList.writeRelays) == [writeRelay, both])
        #expect(published.event.relayListMetadata == recorded.relayList)
    }

    @Test("publishRelayList() with no arguments publishes an empty list with no strategy")
    func publishRelayListDefaults() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub

        try await routing.publishRelayList()

        let recorded = try #require(await stub.relayListPublishes.first)
        #expect(recorded.relayList.entries.isEmpty)
        #expect(recorded.strategy == nil)
    }

    @Test("publishDirectMessageRelayList(relays:) builds the NIP-17 list with the strategy or its default")
    func publishDirectMessageRelayListFromURLs() async throws {
        let stub = RecordingRoutingCapabilities(signer: signer)
        let routing: any NostrRelayRouting = stub
        let second = RelayURL("wss://inbox2.example.com")!

        let published = try await routing.publishDirectMessageRelayList(
            relays: [inboxRelay, second], strategy: .allSettled)
        try await routing.publishDirectMessageRelayList(relays: [inboxRelay])

        let recorded = await stub.directMessageRelayListPublishes
        #expect(
            recorded.map(\.relayList) == [
                DirectMessageRelayList(relays: [inboxRelay, second]), DirectMessageRelayList(relays: [inboxRelay]),
            ])
        #expect(recorded.map(\.strategy) == [.allSettled, nil])
        #expect(published.event.directMessageRelayList?.relays == [inboxRelay, second])
    }
}
