import Foundation
import Testing

@testable import NostrClient

@Suite("NIP-25 Direct Message Reaction Tests")
struct NIP25DirectMessageReactionTests {

    @Test("kind tag carries the integer kind")
    func kindTag() {
        #expect(Tag.kind(.privateDirectMessage).rawArray == ["k", "14"])
    }

    @Test("a built reaction is an unsigned kind-7 rumor referencing the message")
    func buildReaction() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: sender)

        let result = try builder.createReactionWithSelfCopy(
            reaction: "🤙", to: "messageid", author: "authorhex", recipientPubkey: recipient.publicKeyHex)

        #expect(result.rumor.kind == .reaction)
        #expect(result.rumor.content == "🤙")
        #expect(result.rumor.sig.isEmpty)  // NIP-17 rumors are never signed
        #expect(result.rumor.referencedEventIds == ["messageid"])
        #expect(result.rumor.referencedPubkeys == ["authorhex"])
        #expect(result.rumor.firstTagValue(named: "k") == "14")
        #expect(result.recipientGiftWrap.kind == .giftWrap)
    }

    @Test("a reaction round-trips through gift wrap to the recipient")
    func reactionRoundTrip() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: sender)

        let result = try builder.createReactionWithSelfCopy(
            reaction: "+", to: "messageid", author: recipient.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex)

        let reaction = try DirectMessageParser(keyPair: recipient).parseReaction(result.recipientGiftWrap)
        #expect(reaction.content == "+")
        #expect(reaction.messageId == "messageid")
        #expect(reaction.messageAuthorPubkey == recipient.publicKeyHex)
        #expect(reaction.senderPubkey == sender.publicKeyHex)

        // The self-copy decrypts with the sender's own key and carries the identical reaction,
        // guarding against a wrong-key regression when wrapping the self-copy.
        let selfCopy = try DirectMessageParser(keyPair: sender).parseReaction(result.selfGiftWrap)
        #expect(selfCopy.rumorId == reaction.rumorId)
        #expect(selfCopy.content == "+")
        #expect(selfCopy.messageId == "messageid")
        #expect(selfCopy.senderPubkey == sender.publicKeyHex)
    }

    @Test("parsePayload classifies messages and reactions")
    func parsePayloadDispatch() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: sender)
        let parser = DirectMessageParser(keyPair: recipient)

        let message = try builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)
        guard case .message(let parsedMessage) = try parser.parsePayload(message.recipientGiftWrap) else {
            Issue.record("expected a message payload")
            return
        }
        #expect(parsedMessage.content == "hi")

        let reaction = try builder.createReactionWithSelfCopy(
            reaction: "❤️", to: parsedMessage.rumorId, author: sender.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex)
        guard case .reaction(let parsedReaction) = try parser.parsePayload(reaction.recipientGiftWrap) else {
            Issue.record("expected a reaction payload")
            return
        }
        #expect(parsedReaction.content == "❤️")
        #expect(parsedReaction.messageId == parsedMessage.rumorId)
    }

    @Test("parse and parseReaction reject the wrong inner kind")
    func crossParsingRejected() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: sender)
        let parser = DirectMessageParser(keyPair: recipient)

        let message = try builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)
        let reaction = try builder.createReactionWithSelfCopy(
            reaction: "+", to: "mid", author: sender.publicKeyHex, recipientPubkey: recipient.publicKeyHex)

        #expect(throws: NostrError.self) { try parser.parse(reaction.recipientGiftWrap) }
        #expect(throws: NostrError.self) { try parser.parseReaction(message.recipientGiftWrap) }
    }

    @Test("a reaction without an e tag is rejected")
    func reactionWithoutEventTagRejected() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with no "e" tag — not a valid reaction.
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .reaction,
            tags: [.pubkey(sender.publicKeyHex)], content: "+"
        ).asRumor()
        let giftWrap = try GiftWrap.wrap(event: rumor, senderKeyPair: sender, recipientPubkey: recipient.publicKeyHex)

        let parser = DirectMessageParser(keyPair: recipient)
        #expect(throws: NostrError.self) { try parser.parseReaction(giftWrap) }
    }

    @Test("a reaction without a p tag is rejected")
    func reactionWithoutAuthorTagRejected() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with an "e" tag but no "p" tag — author is unknown.
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .reaction,
            tags: [.event("messageid")], content: "+"
        ).asRumor()
        let giftWrap = try GiftWrap.wrap(event: rumor, senderKeyPair: sender, recipientPubkey: recipient.publicKeyHex)

        #expect(throws: NostrError.self) {
            try DirectMessageParser(keyPair: recipient).parseReaction(giftWrap)
        }
    }

    @Test("a disappearing reaction carries the expiration on the gift wrap")
    func reactionWithExpiration() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(keyPair: sender)
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try builder.createReactionWithSelfCopy(
            reaction: "+", to: "mid", author: sender.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let parsed = try DirectMessageParser(keyPair: recipient).parseReaction(result.recipientGiftWrap)
        #expect(parsed.expiresAt == expiry)
    }

    @Test("reactToDirectMessage targets the message author and falls back to the pool")
    func reactRoutingFallsBackToPool() async throws {
        let client = NostrClient()
        try await client.setPrivateKey(String(repeating: "1", count: 64))
        let author = try KeyPair()

        let myPubkey = await client.publicKey ?? ""
        let message = DirectMessage(
            rumorId: "mid", senderPubkey: author.publicKeyHex,
            recipientPubkey: myPubkey, content: "hi", createdAt: Date())

        // Empty pool, no cached DM relay lists: both copies fall back to the (empty) pool.
        let result = try await client.reactToDirectMessage(message, reaction: "+")
        #expect(result.rumor.kind == .reaction)
        #expect(result.rumor.referencedEventIds == ["mid"])
        #expect(result.recipientPublishResult?.statuses.isEmpty == true)
    }
}
