import Foundation
import Testing

@testable import NostrClient

@Suite("Relay Pool Routing Tests (NIP-65)")
struct RelayPoolRoutingTests {

    private let urlA = URL(string: "wss://a.example.com")!
    private let urlB = URL(string: "wss://b.example.com")!
    private let urlC = URL(string: "wss://c.example.com")!
    private let unknown = URL(string: "wss://unknown.example.com")!

    private func makePool() async -> RelayPool {
        let pool = RelayPool()
        await pool.addRelay(url: urlA)
        await pool.addRelay(url: urlB)
        await pool.addRelay(url: urlC)
        return pool
    }

    @Test("targetConnections(nil) returns all relays")
    func targetAllWhenNil() async {
        let pool = await makePool()
        let count = await pool.targetConnections(nil).count
        #expect(count == 3)
    }

    @Test("targetConnections with a subset returns only those relays")
    func targetSubset() async {
        let pool = await makePool()
        let connections = await pool.targetConnections([urlA, urlB])
        #expect(connections.count == 2)
    }

    @Test("targetConnections with a partially-unknown set keeps only present relays")
    func targetPartialUnknown() async {
        let pool = await makePool()
        let connections = await pool.targetConnections([urlA, unknown])
        #expect(connections.count == 1)
    }

    @Test("targetConnections ignores unknown URLs")
    func targetUnknown() async {
        let pool = await makePool()
        let connections = await pool.targetConnections([unknown])
        #expect(connections.isEmpty)
    }

    @Test("targetConnections with an empty set returns nothing")
    func targetEmpty() async {
        let pool = await makePool()
        let connections = await pool.targetConnections([])
        #expect(connections.isEmpty)
    }

    @Test("relay(for:) finds present and absent relays")
    func relayLookup() async {
        let pool = await makePool()
        let present = await pool.relay(for: urlA)
        let absent = await pool.relay(for: unknown)
        #expect(present != nil)
        #expect(absent == nil)
    }

    @Test("count reflects added relays")
    func poolCount() async {
        let pool = await makePool()
        let count = await pool.count
        #expect(count == 3)
    }
}
