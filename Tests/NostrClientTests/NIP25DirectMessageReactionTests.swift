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
        let sender = try KeyPair()
        let recipient = try KeyPair()
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
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: messageID, author: recipient.publicKey,
            recipientPublicKey: recipient.publicKey)

        let reaction = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(
            result.recipientGiftWrap)
        #expect(reaction.content == "+")
        #expect(reaction.messageID == messageID)
        #expect(reaction.messageAuthorPublicKey == recipient.publicKey)
        #expect(reaction.senderPublicKey == sender.publicKey)

        // The self-copy decrypts with the sender's own key and carries the identical reaction,
        // guarding against a wrong-key regression when wrapping the self-copy.
        let selfCopy = try await DirectMessageParser(signer: EventSigner(keyPair: sender)).parseReaction(
            result.selfGiftWrap)
        #expect(selfCopy.rumorID == reaction.rumorID)
        #expect(selfCopy.content == "+")
        #expect(selfCopy.messageID == messageID)
        #expect(selfCopy.senderPublicKey == sender.publicKey)
    }

    @Test("parsePayload classifies messages and reactions")
    func parsePayloadDispatch() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKey)
        guard case .message(let parsedMessage) = try await parser.parsePayload(message.recipientGiftWrap) else {
            Issue.record("expected a message payload")
            return
        }
        #expect(parsedMessage.content == "hi")

        let reaction = try await builder.createReactionWithSelfCopy(
            reaction: "❤️", to: parsedMessage.rumorID, author: sender.publicKey,
            recipientPublicKey: recipient.publicKey)
        guard case .reaction(let parsedReaction) = try await parser.parsePayload(reaction.recipientGiftWrap) else {
            Issue.record("expected a reaction payload")
            return
        }
        #expect(parsedReaction.content == "❤️")
        #expect(parsedReaction.messageID == parsedMessage.rumorID)
    }

    @Test("parse and parseReaction reject the wrong inner kind")
    func crossParsingRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKey)
        let reaction = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: messageID, author: sender.publicKey, recipientPublicKey: recipient.publicKey)

        await #expect(throws: NostrError.self) { try await parser.parse(reaction.recipientGiftWrap) }
        await #expect(throws: NostrError.self) { try await parser.parseReaction(message.recipientGiftWrap) }
    }

    @Test("a reaction without an e tag is rejected")
    func reactionWithoutEventTagRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with no "e" tag — not a valid reaction.
        let rumor = try UnsignedEvent(
            publicKey: sender.publicKey, kind: .reaction,
            tags: [.publicKey(sender.publicKey)], content: "+"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPublicKey: recipient.publicKey)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        await #expect(throws: NostrError.self) { try await parser.parseReaction(giftWrap) }
    }

    @Test("a reaction without a p tag is rejected")
    func reactionWithoutAuthorTagRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with an "e" tag but no "p" tag — author is unknown.
        let rumor = try UnsignedEvent(
            publicKey: sender.publicKey, kind: .reaction,
            tags: [.event(messageID)], content: "+"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPublicKey: recipient.publicKey)

        await #expect(throws: NostrError.self) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(giftWrap)
        }
    }

    @Test(
        "a reaction whose e or p tag is not canonical hex is rejected",
        arguments: [
            [["e", "message"], ["p", authorKey.hex]],
            [["e", messageID.hex], ["p", authorKey.hex.uppercased()]],
        ])
    func reactionWithMalformedReferencesRejected(rawTags: [[String]]) async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        let rumor = try UnsignedEvent(
            publicKey: sender.publicKey, kind: .reaction, rawTags: rawTags, content: "+"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPublicKey: recipient.publicKey)

        await #expect(throws: NostrError.invalidData) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(giftWrap)
        }
    }

    @Test("a disappearing reaction carries the expiration on the gift wrap")
    func reactionWithExpiration() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let expiry = Timestamp(rawValue: 1_700_000_000)

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: messageID, author: sender.publicKey,
            recipientPublicKey: recipient.publicKey, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let parsed = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(
            result.recipientGiftWrap)
        #expect(parsed.expiresAt == expiry)
    }

    @Test("messages.react targets the message author and falls back to the pool")
    func reactRoutingFallsBackToPool() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))
        let author = try KeyPair()

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
        #expect(result.rumor.kind == .reaction)
        #expect(result.rumor.referencedEventIDs == [messageID])
        #expect(result.recipientPublishResult?.acceptedRelays == [ConnectedClientFixture.defaultRelayURL])
        await client.relays.disconnect()
    }
}
