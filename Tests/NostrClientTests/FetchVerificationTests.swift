import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// A relay answers a filter with whatever it likes. A fetch that takes the newest event it was
/// handed therefore trusts the relay rather than the author — and because newer always displaces
/// older, a forged copy dated far ahead wins every time.
@Suite("Fetch Verification Tests")
struct FetchVerificationTests {

    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        try await ConnectedClientFixture.make()
    }

    /// Delivers `events` in answer to the fetch's REQ, then EOSE so the fetch completes.
    private func answering<T: Sendable>(
        _ socket: MockWebSocketSession,
        with events: [Event],
        during fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await fetch() }
        try await pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        guard let frame = socket.sentTextFrames.first(where: { $0.hasPrefix("[\"REQ\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            let subscriptionId = array.count >= 2 ? array[1] as? String : nil
        else {
            throw NostrError.invalidMessageFormat
        }
        for event in events {
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            socket.deliver(.string("[\"EVENT\",\"\(subscriptionId)\",\(json)]"))
        }
        socket.deliver(.string("[\"EOSE\",\"\(subscriptionId)\"]"))
        return try await task.value
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// An event signed by `signer` — the honest case.
    private func signed(
        _ signer: EventSigner,
        kind: Event.Kind,
        createdAt: Int64,
        tags: [[String]] = [],
        content: String = ""
    ) throws -> Event {
        try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey, createdAt: createdAt, kind: kind, rawTags: tags,
                content: content))
    }

    /// An event claiming `pubkey` as its author, with a correct id but a signature that is not
    /// theirs — what a relay can fabricate for anyone.
    private func forged(
        claiming pubkey: String,
        kind: Event.Kind,
        createdAt: Int64,
        tags: [[String]] = [],
        content: String = ""
    ) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: pubkey, createdAt: createdAt, kind: kind, rawTags: tags, content: content)
        return Event(
            id: try unsigned.computedId,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: unsigned.tags,
            content: content,
            sig: String(repeating: "ab", count: 64)
        )
    }

    // MARK: - DM relay list (the routing hijack)

    /// This list decides where a user's private messages are delivered. A forged copy dated ahead
    /// of the real one sends every gift wrap to relays the attacker controls: the recipient never
    /// receives the message, and the sender's metadata goes to whoever forged it.
    @Test("a forged DM relay list cannot displace the real one")
    func forgedDirectMessageRelayListIsIgnored() async throws {
        let (client, socket) = try await makeClient()
        let victim = EventSigner(keyPair: try KeyPair())

        let real = try signed(
            victim, kind: .directMessageRelayList, createdAt: 1_700_000_000,
            tags: [["relay", "wss://real.example.com"]])
        let forgery = try forged(
            claiming: victim.publicKey, kind: .directMessageRelayList,
            createdAt: 2_000_000_000,  // far ahead, so "newest wins" would pick it
            tags: [["relay", "wss://attacker.example.com"]])

        let list = try await answering(socket, with: [real, forgery]) {
            try await client.routing.fetchDirectMessageRelayList(for: victim.publicKey)
        }

        #expect(list?.relays == ["wss://real.example.com"])
        await client.relays.disconnect()
    }

    @Test("a DM relay list attributed to another author is ignored")
    func directMessageRelayListFromAnotherAuthorIsIgnored() async throws {
        let (client, socket) = try await makeClient()
        let victim = EventSigner(keyPair: try KeyPair())
        let stranger = EventSigner(keyPair: try KeyPair())

        // Genuinely signed — but by somebody else.
        let strangersList = try signed(
            stranger, kind: .directMessageRelayList, createdAt: 2_000_000_000,
            tags: [["relay", "wss://attacker.example.com"]])

        let list = try await answering(socket, with: [strangersList]) {
            try await client.routing.fetchDirectMessageRelayList(for: victim.publicKey)
        }

        #expect(list == nil)
        await client.relays.disconnect()
    }

    // MARK: - Relay list and metadata

    @Test("a forged NIP-65 relay list cannot displace the real one")
    func forgedRelayListIsIgnored() async throws {
        let (client, socket) = try await makeClient()
        let victim = EventSigner(keyPair: try KeyPair())

        let real = try signed(
            victim, kind: .relayListMetadata, createdAt: 1_700_000_000,
            tags: [["r", "wss://real.example.com"]])
        let forgery = try forged(
            claiming: victim.publicKey, kind: .relayListMetadata, createdAt: 2_000_000_000,
            tags: [["r", "wss://attacker.example.com"]])

        let list = try await answering(socket, with: [real, forgery]) {
            try await client.routing.fetchRelayList(for: victim.publicKey)
        }

        #expect(list?.entries.map(\.url) == ["wss://real.example.com"])
        await client.relays.disconnect()
    }

    /// Kind 0 is replaceable, but the fetch took whichever copy arrived first — so the profile
    /// depended on which relay answered soonest, and a forged one could win outright.
    @Test("metadata is the newest verified profile, not the first to arrive")
    func metadataPicksNewestVerified() async throws {
        let (client, socket) = try await makeClient()
        let victim = EventSigner(keyPair: try KeyPair())

        let forgery = try forged(
            claiming: victim.publicKey, kind: .setMetadata, createdAt: 2_000_000_000,
            content: #"{"name":"attacker","lud16":"attacker@example.com"}"#)
        let stale = try signed(
            victim, kind: .setMetadata, createdAt: 1_700_000_000, content: #"{"name":"old"}"#)
        let current = try signed(
            victim, kind: .setMetadata, createdAt: 1_800_000_000, content: #"{"name":"current"}"#)

        // The forgery arrives first and is the newest by timestamp: both old selections favoured it.
        let metadata = try await answering(socket, with: [forgery, stale, current]) {
            try await client.events.fetchMetadata(pubkey: victim.publicKey)
        }

        #expect(metadata?.name == "current")
        await client.relays.disconnect()
    }

    // MARK: - Fetch by id

    /// A relay that ignores an id filter can answer with any event; the caller believed it held
    /// the one it asked for.
    @Test("fetchEvent rejects an event that is not the one requested")
    func fetchEventRejectsSubstitute() async throws {
        let (client, socket) = try await makeClient()
        let signer = EventSigner(keyPair: try KeyPair())
        let substitute = try signed(signer, kind: .textNote, createdAt: 1_700_000_000, content: "not it")
        let requestedID = String(repeating: "cd", count: 32)

        let event = try await answering(socket, with: [substitute]) {
            try await client.events.fetchEvent(id: requestedID)
        }

        #expect(event == nil)
        await client.relays.disconnect()
    }

    @Test("fetchEvent returns the requested event when the relay sends it")
    func fetchEventReturnsRequested() async throws {
        let (client, socket) = try await makeClient()
        let signer = EventSigner(keyPair: try KeyPair())
        let wanted = try signed(signer, kind: .textNote, createdAt: 1_700_000_000, content: "the one")

        let event = try await answering(socket, with: [wanted]) {
            try await client.events.fetchEvent(id: wanted.id)
        }

        #expect(event?.id == wanted.id)
        await client.relays.disconnect()
    }

    // MARK: - Selection rules

    /// NIP-01 breaks a `created_at` tie on the lowest id, so every client resolves the conflict the
    /// same way rather than by which relay answered first.
    @Test("a created_at tie is broken by the lowest id")
    func tieIsBrokenByLowestID() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        var candidates: [Event] = []
        for index in 0..<6 {
            candidates.append(
                try signed(
                    signer, kind: .setMetadata, createdAt: 1_700_000_000,
                    content: #"{"name":"n\#(index)"}"#))
        }
        let expected = candidates.map(\.id).min()

        #expect(
            VerifiedEventSelection.newest(
                in: candidates, kind: .setMetadata, author: signer.publicKey)?.id == expected)
        #expect(
            VerifiedEventSelection.newest(
                in: candidates.reversed(), kind: .setMetadata, author: signer.publicKey)?.id == expected)
    }

    @Test("an addressable selection matches the d identifier")
    func addressableSelectionMatchesIdentifier() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let wanted = try signed(
            signer, kind: .longFormContent, createdAt: 1_700_000_000, tags: [["d", "wanted"]])
        let other = try signed(
            signer, kind: .longFormContent, createdAt: 2_000_000_000, tags: [["d", "other"]])

        let picked = VerifiedEventSelection.newest(
            in: [other, wanted], kind: .longFormContent, author: signer.publicKey,
            identifier: "wanted")

        #expect(picked?.id == wanted.id)
    }
}
