import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Published Event Tests")
struct PublishedEventTests {

    private let relayURL = ConnectedClientFixture.defaultRelayURL

    /// A signed-in client backed by one connected mock relay that acks publishes.
    private func makeClient() async throws -> (NostrClient, MockWebSocketSession) {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setSigner(EventSigner(privateKey: PrivateKey(hex: String(repeating: "1", count: 64))))
        return (client, socket)
    }

    @Test("publishTextNote returns the signed event with a publish result")
    func publishTextNoteReturnsPublishedEvent() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "hello nostr")
        }

        #expect(published.event.kind == .textNote)
        #expect(published.event.content == "hello nostr")
        try published.event.verify()
        #expect(published.result.acceptedRelays == [relayURL])
        await client.relays.disconnect()
    }

    @Test("publishReply returns the signed event with a publish result")
    func publishReplyReturnsPublishedEvent() async throws {
        let (client, socket) = try await makeClient()
        let root = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "root note")
        }.event
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishReply(to: root, content: "a reply")
        }

        #expect(published.event.kind == .textNote)
        // NIP-10 positional form: ["e", <id>, <relay-url placeholder>, <marker>]
        #expect(published.event.tags.contains(Event.Tag(rawArray: ["e", root.id.hex, "", "root"])))
        #expect(published.event.tags.contains(Event.Tag(rawArray: ["p", root.publicKey.hex])))
        #expect(published.result.acceptedRelays == [relayURL])
        await client.relays.disconnect()
    }

    @Test("publishReply records the relay hint in the e tag")
    func publishReplyRecordsRelayURL() async throws {
        let (client, socket) = try await makeClient()
        let root = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "root note")
        }.event
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishReply(
                to: root,
                content: "a reply",
                relayURL: RelayURL("wss://hint.example.com")!
            )
        }

        #expect(
            published.event.tags.contains(Event.Tag(rawArray: ["e", root.id.hex, "wss://hint.example.com", "root"])))
        await client.relays.disconnect()
    }

    @Test("publishReaction and publishRepost return published events")
    func reactionAndRepostReturnPublishedEvents() async throws {
        let (client, socket) = try await makeClient()
        let note = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "note")
        }.event

        let reaction = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishReaction(to: note)
        }
        #expect(reaction.event.kind == .reaction)
        #expect(reaction.event.content == "+")

        let repost = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishRepost(of: note)
        }
        #expect(repost.event.kind == .repost)
        #expect(repost.result.acceptedRelays == [relayURL])
        await client.relays.disconnect()
    }

    @Test("publishRepost records the relay hint in the e tag")
    func publishRepostRecordsRelayURL() async throws {
        let (client, socket) = try await makeClient()
        let note = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "note")
        }.event
        let repost = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishRepost(of: note, relayURL: RelayURL("wss://hint.example.com")!)
        }

        #expect(repost.event.kind == .repost)
        #expect(repost.event.tags.contains(Event.Tag(rawArray: ["e", note.id.hex, "wss://hint.example.com"])))
        #expect(repost.event.tags.contains(Event.Tag(rawArray: ["p", note.publicKey.hex])))
        await client.relays.disconnect()
    }

    @Test("publishMetadata and publishDeletion return published events")
    func metadataAndDeletionReturnPublishedEvents() async throws {
        let (client, socket) = try await makeClient()

        let metadata = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishMetadata(UserMetadata(name: "alice"))
        }
        #expect(metadata.event.kind == .setMetadata)

        let deletion = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishDeletion(eventIDs: [metadata.event.id], reason: "cleanup")
        }
        #expect(deletion.event.kind == .eventDeletion)
        #expect(deletion.event.tags.contains(Event.Tag(rawArray: ["e", metadata.event.id.hex])))
        await client.relays.disconnect()
    }

    @Test("routing.publishRelayList returns the published event and caches the list")
    func publishRelayListReturnsPublishedEvent() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishRelayList(
                read: [RelayURL("wss://read.example.com")!],
                write: [RelayURL("wss://write.example.com")!]
            )
        }

        #expect(published.event.kind == .relayListMetadata)
        #expect(published.result.acceptedRelays == [relayURL])

        let publicKey = await client.identity.publicKey
        let cached = await client.routing.cachedRelayList(for: publicKey!)
        #expect(cached != nil)
        await client.relays.disconnect()
    }

    @Test("messages.send reports both publish outcomes")
    func sendDirectMessageReportsPublishOutcomes() async throws {
        let (client, socket) = try await makeClient()
        let recipient = KeyPair()
        let sender = await client.identity.publicKey!
        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)
        await client.dmRelayListStore.markNoList(for: sender)

        // Two EVENT frames: the recipient gift wrap and the self-copy gift wrap.
        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.send("hi", to: recipient.publicKey)
        }

        #expect(result.recipientPublishResult.acceptedRelays == [relayURL])
        #expect(result.selfCopyPublishResult?.acceptedRelays == [relayURL])
        // The rumor id is the key the echoed self-copy is matched by.
        let echoed = try #require(await client.messages.open(result.message.selfGiftWrap).message)
        #expect(echoed.rumorID == result.message.rumor.id)
        await client.relays.disconnect()
    }

    @Test("publish strategy parameter is accepted by convenience methods")
    func strategyParameterAccepted() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "note", strategy: .allSettled)
        }
        #expect(published.result.acceptedRelays == [relayURL])
        await client.relays.disconnect()
    }

    @Test("publishing without a signer throws signerNotSet")
    func publishingWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()

        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.events.publishTextNote(content: "no signer")
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.events.publishMetadata(UserMetadata(name: "x"))
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.messages.send("hi", to: .fixture("pk"))
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.messages.subscribe()
        }
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.routing.publishRelayList(write: [RelayURL("wss://w.example.com")!])
        }
    }

    @Test("messages.open without a signer throws signerNotSet")
    func parseDirectMessageWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()
        let alice = KeyPair()
        let bob = KeyPair()
        let giftWrap = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi", to: bob.publicKey)
            .recipientGiftWrap

        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.messages.open(giftWrap)
        }
    }
}
