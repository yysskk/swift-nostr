import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

private let messageID = EventID.fixture("message")
private let authorKey = PublicKey.fixture("author")

@Suite("NIP-25 Direct Message Reaction Tests")
struct NIP25DirectMessageReactionTests {

    @Test("kind tag carries the integer kind")
    func kindTag() {
        #expect(Tag.kind(.privateDirectMessage).rawArray == ["k", "14"])
    }

    @Test("a built reaction is an unsigned kind-7 rumor referencing the message")
    func buildReaction() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "🤙", to: messageID, author: authorKey, recipientPublicKey: recipient.publicKey)

        #expect(result.rumor.kind == .reaction)
        #expect(result.rumor.content == "🤙")
        #expect(result.rumor.signature == nil)  // NIP-17 rumors are never signed
        #expect(result.rumor.referencedEventIDs == [messageID])
        #expect(result.rumor.referencedPublicKeys == [authorKey])
        #expect(result.rumor.firstTagValue(named: "k") == "14")
        #expect(result.recipientGiftWrap.kind == .giftWrap)
    }

    @Test("a reaction round-trips through gift wrap to the recipient")
    func reactionRoundTrip() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: messageID, author: recipient.publicKey,
            recipientPublicKey: recipient.publicKey)

        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let reaction = try #require(await recipientParser.open(result.recipientGiftWrap).reaction)
        #expect(reaction.content == "+")
        #expect(reaction.messageID == messageID)
        #expect(reaction.messageAuthorPublicKey == recipient.publicKey)
        #expect(reaction.senderPublicKey == sender.publicKey)

        // The self-copy decrypts with the sender's own key and carries the identical reaction,
        // guarding against a wrong-key regression when wrapping the self-copy.
        let senderParser = DirectMessageParser(signer: EventSigner(keyPair: sender))
        let selfCopy = try #require(await senderParser.open(result.selfGiftWrap).reaction)
        #expect(selfCopy.rumorID == reaction.rumorID)
        #expect(selfCopy.content == "+")
        #expect(selfCopy.messageID == messageID)
        #expect(selfCopy.senderPublicKey == sender.publicKey)
    }

    @Test("open classifies messages and reactions")
    func openDispatch() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKey)
        guard case .message(let parsedMessage) = try await parser.open(message.recipientGiftWrap) else {
            Issue.record("expected a message payload")
            return
        }
        #expect(parsedMessage.content == "hi")

        let reaction = try await builder.createReactionWithSelfCopy(
            reaction: "❤️", to: parsedMessage.rumorID, author: sender.publicKey,
            recipientPublicKey: recipient.publicKey)
        guard case .reaction(let parsedReaction) = try await parser.open(reaction.recipientGiftWrap) else {
            Issue.record("expected a reaction payload")
            return
        }
        #expect(parsedReaction.content == "❤️")
        #expect(parsedReaction.messageID == parsedMessage.rumorID)
    }

    @Test("a reaction without an e tag is rejected")
    func reactionWithoutEventTagRejected() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        // Hand-built kind-7 rumor with no "e" tag — not a valid reaction.
        let template = EventTemplate(
            kind: .reaction,
            tags: [.publicKey(sender.publicKey)], content: "+"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: sender), to: recipient.publicKey)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        await #expect(throws: DirectMessagePayload.Error.missingReactionTarget) {
            try await parser.open(giftWrap)
        }
    }

    @Test("a reaction without a p tag is rejected")
    func reactionWithoutAuthorTagRejected() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        // Hand-built kind-7 rumor with an "e" tag but no "p" tag — author is unknown.
        let template = EventTemplate(
            kind: .reaction,
            tags: [.event(messageID)], content: "+"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: sender), to: recipient.publicKey)

        await #expect(throws: DirectMessagePayload.Error.missingReactionTarget) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    @Test(
        "a reaction whose e or p tag is not canonical hex is rejected",
        arguments: [
            [Event.Tag(name: .event, values: ["message"]), .publicKey(authorKey)],
            [.event(messageID), Event.Tag(name: .publicKey, values: [authorKey.hex.uppercased()])],
        ])
    func reactionWithMalformedReferencesRejected(tags: [Event.Tag]) async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        let template = EventTemplate(
            kind: .reaction, tags: tags, content: "+"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: sender), to: recipient.publicKey)

        await #expect(throws: DirectMessagePayload.Error.missingReactionTarget) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    @Test("a disappearing reaction carries the expiration on the gift wrap")
    func reactionWithExpiration() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let expiry = Timestamp(rawValue: 1_700_000_000)

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: messageID, author: sender.publicKey,
            recipientPublicKey: recipient.publicKey, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let parsed = try #require(await recipientParser.open(result.recipientGiftWrap).reaction)
        #expect(parsed.expiresAt == expiry)
    }

    @Test("messages.react targets the message author and falls back to the pool")
    func reactRoutingFallsBackToPool() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setSigner(EventSigner(privateKey: PrivateKey(hex: String(repeating: "1", count: 64))))
        let author = KeyPair()

        let myPublicKey = try #require(await client.identity.publicKey)
        let message = DirectMessage(
            rumorID: messageID, senderPublicKey: author.publicKey,
            recipientPublicKey: myPublicKey, content: "hi", createdAt: .now)

        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: author.publicKey)
        await client.dmRelayListStore.markNoList(for: myPublicKey)

        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.react(to: message, reaction: "+")
        }
        #expect(result.message.rumor.kind == .reaction)
        #expect(result.message.rumor.referencedEventIDs == [messageID])
        #expect(result.recipientPublishResult.acceptedRelays == [ConnectedClientFixture.defaultRelayURL])
        await client.relays.disconnect()
    }
}
