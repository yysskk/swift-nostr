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
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        return (client, socket)
    }

    @Test("dynamic member lookup forwards Event properties")
    func dynamicMemberLookupForwardsEventProperties() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)
        let event = try signer.signTextNote(content: "hello")
        let published = PublishedEvent(
            event: event,
            result: PublishResult(statuses: [relayURL: .accepted])
        )

        #expect(published.id == event.id)
        #expect(published.kind == event.kind)
        #expect(published.content == "hello")
        #expect(published.event == event)
        #expect(published.result.acceptedRelays == [relayURL])
    }

    @Test("publishTextNote returns the signed event with a publish result")
    func publishTextNoteReturnsPublishedEvent() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.events.publishTextNote(content: "hello nostr")
        }

        #expect(published.event.kind == .textNote)
        #expect(published.content == "hello nostr")
        #expect(try published.event.verify())
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
        #expect(published.event.tags.contains(["e", root.id, "", "root"]))
        #expect(published.event.tags.contains(["p", root.pubkey]))
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
                relayURL: "wss://hint.example.com"
            )
        }

        #expect(published.event.tags.contains(["e", root.id, "wss://hint.example.com", "root"]))
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
        #expect(reaction.content == "+")

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
            try await client.events.publishRepost(of: note, relayURL: "wss://hint.example.com")
        }

        #expect(repost.event.kind == .repost)
        #expect(repost.event.tags.contains(["e", note.id, "wss://hint.example.com"]))
        #expect(repost.event.tags.contains(["p", note.pubkey]))
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
            try await client.events.publishDeletion(eventIds: [metadata.id], reason: "cleanup")
        }
        #expect(deletion.event.kind == .eventDeletion)
        #expect(deletion.event.tags.contains(["e", metadata.id]))
        await client.relays.disconnect()
    }

    @Test("routing.publishRelayList returns the published event and caches the list")
    func publishRelayListReturnsPublishedEvent() async throws {
        let (client, socket) = try await makeClient()
        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await client.routing.publishRelayList(
                read: ["wss://read.example.com"],
                write: ["wss://write.example.com"]
            )
        }

        #expect(published.event.kind == .relayListMetadata)
        #expect(published.result.acceptedRelays == [relayURL])

        let pubkey = await client.identity.publicKey
        let cached = await client.routing.cachedRelayList(for: pubkey!)
        #expect(cached != nil)
        await client.relays.disconnect()
    }

    @Test("messages.send reports both publish outcomes")
    func sendDirectMessageReportsPublishOutcomes() async throws {
        let (client, socket) = try await makeClient()
        let recipient = try KeyPair()
        let sender = await client.identity.publicKey!
        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: recipient.publicKeyHex)
        await client.dmRelayListStore.markNoList(for: sender)

        // Two EVENT frames: the recipient gift wrap and the self-copy gift wrap.
        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.send("hi", to: recipient.publicKeyHex)
        }

        #expect(result.recipientPublishResult?.acceptedRelays == [relayURL])
        #expect(result.selfCopyPublishResult?.acceptedRelays == [relayURL])
        await client.relays.disconnect()
    }

    @Test("SendDirectMessageResult publish results default to nil")
    func sendDirectMessageResultDefaultsToNilPublishResults() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let result = try await builder.createMessageWithSelfCopy(content: "hi", to: bob.publicKeyHex)

        #expect(result.recipientPublishResult == nil)
        #expect(result.selfCopyPublishResult == nil)
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

        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.events.publishTextNote(content: "no signer")
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.events.publishMetadata(UserMetadata(name: "x"))
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.messages.send("hi", to: "pk")
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.messages.subscribe()
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.routing.publishRelayList(write: ["wss://w.example.com"])
        }
    }

    @Test("messages.parse without a signer throws signerNotSet")
    func parseDirectMessageWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()
        let alice = try KeyPair()
        let bob = try KeyPair()
        let giftWrap = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi", to: bob.publicKeyHex)
            .recipientGiftWrap

        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.messages.parse(giftWrap)
        }
    }
}
