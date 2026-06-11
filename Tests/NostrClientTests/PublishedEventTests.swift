import Foundation
import Testing

@testable import NostrClient

@Suite("Published Event Tests")
struct PublishedEventTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeClient() async throws -> NostrClient {
        let client = NostrClient()
        try await client.setPrivateKey(String(repeating: "1", count: 64))
        return client
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
        let client = try await makeClient()
        let published = try await client.publishTextNote(content: "hello nostr")

        #expect(published.event.kind == .textNote)
        #expect(published.content == "hello nostr")
        #expect(try published.event.verify())
        // Empty pool: nothing was targeted, so the result carries no statuses.
        #expect(published.result.statuses.isEmpty)
    }

    @Test("publishReply returns the signed event with a publish result")
    func publishReplyReturnsPublishedEvent() async throws {
        let client = try await makeClient()
        let root = try await client.publishTextNote(content: "root note").event
        let published = try await client.publishReply(to: root, content: "a reply")

        #expect(published.event.kind == .textNote)
        // NIP-10 positional form: ["e", <id>, <relay-url placeholder>, <marker>]
        #expect(published.event.tags.contains(["e", root.id, "", "root"]))
        #expect(published.event.tags.contains(["p", root.pubkey]))
        #expect(published.result.statuses.isEmpty)
    }

    @Test("publishReaction and publishRepost return published events")
    func reactionAndRepostReturnPublishedEvents() async throws {
        let client = try await makeClient()
        let note = try await client.publishTextNote(content: "note").event

        let reaction = try await client.publishReaction(to: note)
        #expect(reaction.event.kind == .reaction)
        #expect(reaction.content == "+")

        let repost = try await client.publishRepost(of: note)
        #expect(repost.event.kind == .repost)
        #expect(repost.result.statuses.isEmpty)
    }

    @Test("publishMetadata and publishDeletion return published events")
    func metadataAndDeletionReturnPublishedEvents() async throws {
        let client = try await makeClient()

        let metadata = try await client.publishMetadata(UserMetadata(name: "alice"))
        #expect(metadata.event.kind == .setMetadata)

        let deletion = try await client.publishDeletion(eventIds: [metadata.id], reason: "cleanup")
        #expect(deletion.event.kind == .eventDeletion)
        #expect(deletion.event.tags.contains(["e", metadata.id]))
    }

    @Test("publishRelayList returns the published event and caches the list")
    func publishRelayListReturnsPublishedEvent() async throws {
        let client = try await makeClient()
        let published = try await client.publishRelayList(
            read: ["wss://read.example.com"],
            write: ["wss://write.example.com"]
        )

        #expect(published.event.kind == .relayListMetadata)
        #expect(published.result.statuses.isEmpty)

        let pubkey = await client.publicKey
        let cached = await client.cachedRelayList(for: pubkey!)
        #expect(cached != nil)
    }

    @Test("sendDirectMessage reports both publish outcomes")
    func sendDirectMessageReportsPublishOutcomes() async throws {
        let client = try await makeClient()
        let recipient = try KeyPair()

        let result = try await client.sendDirectMessage("hi", to: recipient.publicKeyHex)

        #expect(result.recipientPublishResult != nil)
        #expect(result.selfCopyPublishResult != nil)
        #expect(result.recipientPublishResult?.statuses.isEmpty == true)
    }

    @Test("SendDirectMessageResult publish results default to nil")
    func sendDirectMessageResultDefaultsToNilPublishResults() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: alice)
        let result = try builder.createMessageWithSelfCopy(content: "hi", to: bob.publicKeyHex)

        #expect(result.recipientPublishResult == nil)
        #expect(result.selfCopyPublishResult == nil)
    }

    @Test("publish strategy parameter is accepted by convenience methods")
    func strategyParameterAccepted() async throws {
        let client = try await makeClient()
        // Empty pool: strategies are satisfied trivially; this guards the API shape.
        let published = try await client.publishTextNote(content: "note", strategy: .allSettled)
        #expect(published.result.statuses.isEmpty)
    }

    @Test("publishing without a signer throws signerNotSet")
    func publishingWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()

        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.publishTextNote(content: "no signer")
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.publishMetadata(UserMetadata(name: "x"))
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.sendDirectMessage("hi", to: "pk")
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.directMessages()
        }
        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.publishRelayList(write: ["wss://w.example.com"])
        }
    }
}
