import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

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
    func reactionRoundTrip() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: "messageid", author: recipient.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex)

        let reaction = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(
            result.recipientGiftWrap)
        #expect(reaction.content == "+")
        #expect(reaction.messageId == "messageid")
        #expect(reaction.messageAuthorPubkey == recipient.publicKeyHex)
        #expect(reaction.senderPubkey == sender.publicKeyHex)

        // The self-copy decrypts with the sender's own key and carries the identical reaction,
        // guarding against a wrong-key regression when wrapping the self-copy.
        let selfCopy = try await DirectMessageParser(signer: EventSigner(keyPair: sender)).parseReaction(
            result.selfGiftWrap)
        #expect(selfCopy.rumorId == reaction.rumorId)
        #expect(selfCopy.content == "+")
        #expect(selfCopy.messageId == "messageid")
        #expect(selfCopy.senderPubkey == sender.publicKeyHex)
    }

    @Test("parsePayload classifies messages and reactions")
    func parsePayloadDispatch() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)
        guard case .message(let parsedMessage) = try await parser.parsePayload(message.recipientGiftWrap) else {
            Issue.record("expected a message payload")
            return
        }
        #expect(parsedMessage.content == "hi")

        let reaction = try await builder.createReactionWithSelfCopy(
            reaction: "❤️", to: parsedMessage.rumorId, author: sender.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex)
        guard case .reaction(let parsedReaction) = try await parser.parsePayload(reaction.recipientGiftWrap) else {
            Issue.record("expected a reaction payload")
            return
        }
        #expect(parsedReaction.content == "❤️")
        #expect(parsedReaction.messageId == parsedMessage.rumorId)
    }

    @Test("parse and parseReaction reject the wrong inner kind")
    func crossParsingRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)
        let reaction = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: "mid", author: sender.publicKeyHex, recipientPubkey: recipient.publicKeyHex)

        await #expect(throws: NostrError.self) { try await parser.parse(reaction.recipientGiftWrap) }
        await #expect(throws: NostrError.self) { try await parser.parseReaction(message.recipientGiftWrap) }
    }

    @Test("a reaction without an e tag is rejected")
    func reactionWithoutEventTagRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with no "e" tag — not a valid reaction.
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .reaction,
            tags: [.pubkey(sender.publicKeyHex)], content: "+"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPubkey: recipient.publicKeyHex)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        await #expect(throws: NostrError.self) { try await parser.parseReaction(giftWrap) }
    }

    @Test("a reaction without a p tag is rejected")
    func reactionWithoutAuthorTagRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-7 rumor with an "e" tag but no "p" tag — author is unknown.
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .reaction,
            tags: [.event("messageid")], content: "+"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPubkey: recipient.publicKeyHex)

        await #expect(throws: NostrError.self) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(giftWrap)
        }
    }

    @Test("a disappearing reaction carries the expiration on the gift wrap")
    func reactionWithExpiration() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try await builder.createReactionWithSelfCopy(
            reaction: "+", to: "mid", author: sender.publicKeyHex,
            recipientPubkey: recipient.publicKeyHex, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let parsed = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseReaction(
            result.recipientGiftWrap)
        #expect(parsed.expiresAt == expiry)
    }

    @Test("reactToDirectMessage targets the message author and falls back to the pool")
    func reactRoutingFallsBackToPool() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.setPrivateKey(String(repeating: "1", count: 64))
        let author = try KeyPair()

        let myPubkey = await client.publicKey ?? ""
        let message = DirectMessage(
            rumorId: "mid", senderPubkey: author.publicKeyHex,
            recipientPubkey: myPubkey, content: "hi", createdAt: Date())

        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay
        // without a discovery fetch.
        await client.dmRelayListStore.markNoList(for: author.publicKeyHex)
        await client.dmRelayListStore.markNoList(for: myPubkey)

        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.reactToDirectMessage(message, reaction: "+")
        }
        #expect(result.rumor.kind == .reaction)
        #expect(result.rumor.referencedEventIds == ["mid"])
        #expect(result.recipientPublishResult?.acceptedRelays == [ConnectedClientFixture.defaultRelayURL])
        await client.disconnect()
    }
}
