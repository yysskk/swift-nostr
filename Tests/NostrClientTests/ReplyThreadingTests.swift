import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// NIP-10 puts the marker at a fixed position in an `e` tag — `["e", <id>, <relay>, <marker>]` — so
/// a reply's thread root has to be read from there. Comparing every element against "root" instead
/// matches a relay hint that happens to equal it, and leaves a thread written in NIP-10's
/// deprecated positional form looking rootless, which forks the thread.
/// https://github.com/nostr-protocol/nips/blob/master/10.md
@Suite("NIP-10 Reply Threading Tests")
struct ReplyThreadingTests {
    private let rootID = String(repeating: "11", count: 32)

    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        return (client, socket)
    }

    /// Publishes a reply to a parent carrying `parentTags` and returns the reply's `e` tags.
    private func replyEventTags(toParentWith parentTags: [[String]]) async throws -> [[String]] {
        let (client, socket) = try await makeClient()
        defer { Task { await client.relays.disconnect() } }

        let signer = EventSigner(keyPair: try KeyPair())
        let parent = try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey,
                createdAt: 1_700_000_000,
                kind: .textNote,
                rawTags: parentTags,
                content: "parent"
            )
        )

        let reply = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishReply(to: parent, content: "a reply")
        }

        return reply.event.tags.filter { $0.first == "e" }
    }

    @Test("the marked root is carried over")
    func markedRootIsCarriedOver() async throws {
        let parentID = String(repeating: "22", count: 32)
        let tags = try await replyEventTags(toParentWith: [
            ["e", rootID, "wss://relay.example.com", "root"],
            ["e", parentID, "wss://relay.example.com", "reply"],
        ])

        #expect(tags.contains(["e", rootID, "wss://relay.example.com", "root"]))
        #expect(tags.contains { $0.count >= 4 && $0[3] == "reply" })
    }

    /// The marker was matched against every element of the tag rather than its own position, so a
    /// value of "root" anywhere counted. Here it sits in the relay-hint slot of a tag explicitly
    /// marked "reply", and the reply was threaded under it as though it were the root.
    @Test("a value of root outside the marker position is not a marker")
    func rootOutsideMarkerPositionIsNotAMarker() async throws {
        let parentID = String(repeating: "22", count: 32)
        let tags = try await replyEventTags(toParentWith: [
            ["e", parentID, "root", "reply"]
        ])

        // The parent carries markers but no root marker, so it is itself the root: the reply names
        // the parent as root and carries nothing over.
        #expect(!tags.contains(["e", parentID, "root", "reply"]))
        #expect(tags.contains { $0.count >= 4 && $0[3] == "root" })
    }

    /// NIP-10's deprecated positional form carries no markers, and there the first `e` tag is the
    /// root. Treated as rootless, the reply started a second thread beside the one it answered.
    ///
    /// The recovered root is re-emitted with an explicit marker rather than copied through:
    /// appending it unmarked next to a `reply`-marked tag would leave a mixed set, which
    /// marked-scheme readers take to mean a mention — losing the thread this recovery preserves.
    @Test("the first e tag is the root when no markers are present")
    func positionalRootIsCarriedOver() async throws {
        let parentID = String(repeating: "22", count: 32)
        let tags = try await replyEventTags(toParentWith: [
            ["e", rootID],
            ["e", parentID],
        ])

        #expect(tags.contains { $0.count >= 4 && $0[1] == rootID && $0[3] == "root" })
        // The reply points at the parent event itself, not at the id in one of its tags.
        #expect(tags.contains { $0.count >= 4 && $0[1] != rootID && $0[3] == "reply" })
    }

    /// A relay hint on the positional root is preserved when the tag is re-emitted.
    @Test("a positional root keeps its relay hint")
    func positionalRootKeepsRelayHint() async throws {
        let parentID = String(repeating: "22", count: 32)
        let tags = try await replyEventTags(toParentWith: [
            ["e", rootID, "wss://hint.example.com"],
            ["e", parentID, "wss://hint.example.com"],
        ])

        #expect(tags.contains(["e", rootID, "wss://hint.example.com", "root"]))
    }

    @Test("an event with no e tags is its own root")
    func noEventTagsMeansRoot() async throws {
        let tags = try await replyEventTags(toParentWith: [["p", String(repeating: "33", count: 32)]])

        #expect(tags.count == 1)
        #expect(tags[0].count >= 4 && tags[0][3] == "root")
    }

    @Test("a marked thread with no root marker is treated as rootless")
    func markedButRootlessThread() async throws {
        let parentID = String(repeating: "22", count: 32)
        let tags = try await replyEventTags(toParentWith: [
            ["e", parentID, "wss://relay.example.com", "mention"]
        ])

        #expect(tags.count == 1)
        #expect(tags[0].count >= 4 && tags[0][3] == "root")
    }
}
