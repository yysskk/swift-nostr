import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrListManaging`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows what each one
/// forwards — the author (nil for the current user, or the given key), identifier, timeout, and
/// strategy — without a relay pool.
@Suite("List Capability Tests")
struct ListCapabilityTests {
    private let signer: EventSigner
    private let other = PublicKey.fixture("other")

    init() throws {
        signer = EventSigner(keyPair: KeyPair())
    }

    private func makeStub(cannedSet: NostrListSet? = nil) -> RecordingListCapabilities {
        RecordingListCapabilities(signer: signer, cannedSet: cannedSet)
    }

    // MARK: - Publishing

    @Test("publish(_:) and publishSet(_:) forward no strategy")
    func publishShortForms() async throws {
        let stub = makeStub()
        let lists: any NostrListManaging = stub
        let bookmarks = NostrList(kind: .bookmarkList, publicItems: [.event(.fixture("note"))])
        let reading = try NostrListSet(kind: .bookmarkSet, identifier: "reading", title: "Reading")

        let listEvent = try await lists.publish(bookmarks)
        let setEvent = try await lists.publishSet(reading)

        let listPublishes = await stub.listPublishes
        #expect(listPublishes.map(\.list) == [bookmarks])
        #expect(listPublishes.map(\.strategy) == [nil])
        #expect(listEvent.event.kind == .bookmarkList)

        let setPublishes = await stub.setPublishes
        #expect(setPublishes.map(\.set) == [reading])
        #expect(setPublishes.map(\.strategy) == [nil])
        #expect(setEvent.event.kind == .bookmarkSet)
    }

    // MARK: - Fetching

    @Test("fetch(kind:) asks for the current user's list, and fetch(kind:for:) for the given author")
    func fetchShortForms() async throws {
        let stub = makeStub()
        let lists: any NostrListManaging = stub

        _ = try await lists.fetch(kind: .muteList)
        _ = try await lists.fetch(kind: .muteList, timeout: .seconds(3))
        _ = try await lists.fetch(kind: .muteList, for: other)
        _ = try await lists.fetch(kind: .muteList, for: other, timeout: .seconds(4))

        #expect(
            await stub.listFetches == [
                .init(kind: .muteList, identifier: nil, publicKey: nil, timeout: nil),
                .init(kind: .muteList, identifier: nil, publicKey: nil, timeout: .seconds(3)),
                .init(kind: .muteList, identifier: nil, publicKey: other, timeout: nil),
                .init(kind: .muteList, identifier: nil, publicKey: other, timeout: .seconds(4)),
            ])
    }

    @Test("fetchSet(kind:identifier:) asks for the current user's set, and with for: for the given author")
    func fetchSetShortForms() async throws {
        let stub = makeStub()
        let lists: any NostrListManaging = stub

        _ = try await lists.fetchSet(kind: .bookmarkSet, identifier: "reading")
        _ = try await lists.fetchSet(kind: .bookmarkSet, identifier: "reading", timeout: .seconds(3))
        _ = try await lists.fetchSet(kind: .bookmarkSet, identifier: "reading", for: other)
        _ = try await lists.fetchSet(kind: .bookmarkSet, identifier: "reading", for: other, timeout: .seconds(4))

        #expect(
            await stub.setFetches == [
                .init(kind: .bookmarkSet, identifier: "reading", publicKey: nil, timeout: nil),
                .init(kind: .bookmarkSet, identifier: "reading", publicKey: nil, timeout: .seconds(3)),
                .init(kind: .bookmarkSet, identifier: "reading", publicKey: other, timeout: nil),
                .init(kind: .bookmarkSet, identifier: "reading", publicKey: other, timeout: .seconds(4)),
            ])
    }

    @Test("fetchSets(kind:) asks for the current user's sets, and with for: for the given author")
    func fetchSetsShortForms() async throws {
        let stub = makeStub()
        let lists: any NostrListManaging = stub

        _ = try await lists.fetchSets(kind: .followSet)
        _ = try await lists.fetchSets(kind: .followSet, timeout: .seconds(3))
        _ = try await lists.fetchSets(kind: .followSet, for: other)
        _ = try await lists.fetchSets(kind: .followSet, for: other, timeout: .seconds(4))

        #expect(
            await stub.setsFetches == [
                .init(kind: .followSet, identifier: nil, publicKey: nil, timeout: nil),
                .init(kind: .followSet, identifier: nil, publicKey: nil, timeout: .seconds(3)),
                .init(kind: .followSet, identifier: nil, publicKey: other, timeout: nil),
                .init(kind: .followSet, identifier: nil, publicKey: other, timeout: .seconds(4)),
            ])
    }

    @Test("fetchSet(naddr:) fetches the coordinate's kind, identifier, and author, and returns the set")
    func fetchSetByNAddr() async throws {
        let reading = try NostrListSet(kind: .bookmarkSet, identifier: "reading")
        let stub = makeStub(cannedSet: reading)
        let lists: any NostrListManaging = stub
        let addr = try NAddr(
            identifier: "reading", author: other, kind: 30003, relays: [RelayURL("wss://hint.example.com")!])

        let fetched = try await lists.fetchSet(naddr: addr, timeout: .seconds(2))

        #expect(fetched == reading)
        #expect(
            await stub.setFetches == [
                .init(kind: .bookmarkSet, identifier: "reading", publicKey: other, timeout: .seconds(2))
            ])
    }

    @Test("fetchSet(naddr:) names the author even for the current user's own set, so nothing is decrypted")
    func fetchSetByNAddrNeverAsksForTheCurrentUser() async throws {
        let stub = makeStub()
        let lists: any NostrListManaging = stub
        let own = try NAddr(identifier: "mine", author: signer.publicKey, kind: 30003)

        _ = try await lists.fetchSet(naddr: own)

        #expect(
            await stub.setFetches == [
                .init(kind: .bookmarkSet, identifier: "mine", publicKey: signer.publicKey, timeout: nil)
            ])
    }
}
