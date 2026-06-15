import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-17 Private Direct Message Tests")
struct NIP17Tests {

    // MARK: - NIP-44 Encryption Tests

    @Test("NIP-44 seal and open message")
    func nip44SealOpen() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let originalMessage = "Hello, Bob! This is a private message."

        // Alice seals a message for Bob
        let sealed = try SealedMessage.seal(originalMessage, for: bob.publicKeyHex, using: alice)

        // Verify it's base64 encoded
        #expect(Data(base64Encoded: sealed.payload) != nil)

        // Bob opens the message from Alice
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == originalMessage)
    }

    @Test("NIP-44 sender can open own message")
    func nip44SenderOpen() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let originalMessage = "Hello, Bob!"

        let sealed = try SealedMessage.seal(originalMessage, for: bob.publicKeyHex, using: alice)

        // Alice can open using Bob's pubkey (same shared secret)
        let opened = try sealed.open(from: bob.publicKeyHex, using: alice)

        #expect(opened == originalMessage)
    }

    @Test("NIP-44 with special characters")
    func nip44SpecialCharacters() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let originalMessage = "Hello! 🎉 Special: <>&\"'日本語中文한국어"

        let sealed = try SealedMessage.seal(originalMessage, for: bob.publicKeyHex, using: alice)
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == originalMessage)
    }

    @Test("NIP-44 with long message")
    func nip44LongMessage() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let originalMessage = String(repeating: "A", count: 10000)

        let sealed = try SealedMessage.seal(originalMessage, for: bob.publicKeyHex, using: alice)
        let opened = try sealed.open(from: alice.publicKeyHex, using: bob)

        #expect(opened == originalMessage)
    }

    @Test("NIP-44 version check")
    func nip44VersionCheck() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let sealed = try SealedMessage.seal("test", for: bob.publicKeyHex, using: alice)
        let payload = Data(base64Encoded: sealed.payload)!

        // First byte should be version 2
        #expect(payload[0] == 2)
    }

    // MARK: - Gift Wrap Tests

    @Test("Gift wrap and unwrap")
    func giftWrapUnwrap() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        // Create a simple event
        let signer = EventSigner(keyPair: alice)
        let originalEvent = try signer.signTextNote(content: "Secret message")

        // Alice wraps the event for Bob
        let wrapped = try GiftWrap.wrap(
            event: originalEvent,
            senderKeyPair: alice,
            recipientPubkey: bob.publicKeyHex
        )

        // Verify it's a gift wrap event
        #expect(wrapped.kind == .giftWrap)

        // Verify the p tag points to Bob
        let pTag = wrapped.tags.first { $0.first == "p" }
        #expect(pTag?[1] == bob.publicKeyHex)

        // Bob unwraps the event
        let unwrapped = try GiftWrap.unwrap(giftWrap: wrapped, recipientKeyPair: bob)

        #expect(unwrapped.senderPubkey == alice.publicKeyHex)
        #expect(unwrapped.event.content == "Secret message")
    }

    @Test("Gift wrap uses ephemeral key")
    func giftWrapEphemeralKey() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let signer = EventSigner(keyPair: alice)
        let event = try signer.signTextNote(content: "Test")

        let wrapped = try GiftWrap.wrap(
            event: event,
            senderKeyPair: alice,
            recipientPubkey: bob.publicKeyHex
        )

        // The gift wrap pubkey should NOT be Alice's pubkey (it's ephemeral)
        #expect(wrapped.pubkey != alice.publicKeyHex)
    }

    // MARK: - Direct Message Tests

    @Test("Create and parse direct message")
    func directMessageRoundTrip() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let giftWrap = try builder.createMessageWithSelfCopy(
            content: "Hello Bob!",
            to: bob.publicKeyHex,
            subject: "Test Subject"
        ).recipientGiftWrap

        // Verify it's a gift wrap
        #expect(giftWrap.kind == .giftWrap)

        // Bob parses the message
        let parser = DirectMessageParser(keyPair: bob)
        let message = try parser.parse(giftWrap)

        #expect(message.content == "Hello Bob!")
        #expect(message.senderPubkey == alice.publicKeyHex)
        #expect(message.subject == "Test Subject")
    }

    @Test("Direct message with reply")
    func directMessageReply() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)

        // First message
        let firstMessage = try builder.createMessageWithSelfCopy(
            content: "First message",
            to: bob.publicKeyHex
        ).recipientGiftWrap

        let parser = DirectMessageParser(keyPair: bob)
        let parsedFirst = try parser.parse(firstMessage)

        // Reply to first message
        let bobBuilder = DirectMessageBuilder(keyPair: bob)
        let reply = try bobBuilder.createMessageWithSelfCopy(
            content: "Reply to first",
            to: alice.publicKeyHex,
            replyTo: parsedFirst.rumorId
        ).recipientGiftWrap

        let aliceParser = DirectMessageParser(keyPair: alice)
        let parsedReply = try aliceParser.parse(reply)

        #expect(parsedReply.content == "Reply to first")
        #expect(parsedReply.replyTo == parsedFirst.rumorId)
    }

    @Test("Group message creates multiple gift wraps")
    func groupMessage() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let charlie = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let giftWraps = try builder.createGroupMessage(
            content: "Hello everyone!",
            to: [bob.publicKeyHex, charlie.publicKeyHex],
            subject: "Group Chat"
        )

        // Should create 3 gift wraps: one for bob, one for charlie, one for alice (sender)
        #expect(giftWraps.count == 3)

        // Bob can parse his copy
        let bobParser = DirectMessageParser(keyPair: bob)
        let bobMessage = try bobParser.parse(giftWraps[0])
        #expect(bobMessage.content == "Hello everyone!")

        // Charlie can parse his copy
        let charlieParser = DirectMessageParser(keyPair: charlie)
        let charlieMessage = try charlieParser.parse(giftWraps[1])
        #expect(charlieMessage.content == "Hello everyone!")

        // Alice can parse her copy
        let aliceParser = DirectMessageParser(keyPair: alice)
        let aliceMessage = try aliceParser.parse(giftWraps[2])
        #expect(aliceMessage.content == "Hello everyone!")
    }

    // MARK: - Self-Copy Tests

    @Test("Self-copy shares one unsigned rumor across both gift wraps")
    func selfCopySharesRumor() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let result = try builder.createMessageWithSelfCopy(
            content: "Hello Bob!",
            to: bob.publicKeyHex,
            subject: "Test Subject"
        )

        // The rumor is an unsigned kind 14 with a computed id
        #expect(result.rumor.kind == .privateDirectMessage)
        #expect(result.rumor.sig.isEmpty)
        #expect(!result.rumor.id.isEmpty)

        // Each wrap is addressed to its own recipient
        #expect(result.recipientGiftWrap.tags.first { $0.first == "p" }?[1] == bob.publicKeyHex)
        #expect(result.selfGiftWrap.tags.first { $0.first == "p" }?[1] == alice.publicKeyHex)

        // Bob unwraps the recipient copy, Alice unwraps the self-copy — same rumor
        let bobUnwrapped = try GiftWrap.unwrap(giftWrap: result.recipientGiftWrap, recipientKeyPair: bob)
        let aliceUnwrapped = try GiftWrap.unwrap(giftWrap: result.selfGiftWrap, recipientKeyPair: alice)

        #expect(bobUnwrapped.event.id == result.rumor.id)
        #expect(aliceUnwrapped.event.id == result.rumor.id)
        #expect(bobUnwrapped.event.content == "Hello Bob!")
        #expect(aliceUnwrapped.event.content == "Hello Bob!")
        #expect(bobUnwrapped.senderPubkey == alice.publicKeyHex)
        #expect(aliceUnwrapped.senderPubkey == alice.publicKeyHex)
    }

    @Test("Self-copy parses identically for sender and recipient")
    func selfCopyParsesOnBothSides() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let result = try builder.createMessageWithSelfCopy(
            content: "Hello again",
            to: bob.publicKeyHex,
            subject: "Subject",
            replyTo: String(repeating: "d", count: 64)
        )

        let bobMessage = try DirectMessageParser(keyPair: bob).parse(result.recipientGiftWrap)
        let aliceMessage = try DirectMessageParser(keyPair: alice).parse(result.selfGiftWrap)

        // The rumor id is the echo-matching key on both sides
        #expect(bobMessage.rumorId == result.rumor.id)
        #expect(aliceMessage.rumorId == result.rumor.id)
        #expect(aliceMessage.content == bobMessage.content)
        #expect(aliceMessage.subject == bobMessage.subject)
        #expect(aliceMessage.replyTo == bobMessage.replyTo)
        #expect(aliceMessage.senderPubkey == alice.publicKeyHex)
        #expect(aliceMessage.recipientPubkey == bob.publicKeyHex)
    }

    @Test("Rumor id matches the id the signing path would produce")
    func rumorIdMatchesSignedId() throws {
        let alice = try KeyPair()

        let unsigned = UnsignedEvent(
            pubkey: alice.publicKeyHex,
            createdAt: 1_700_000_000,
            kind: .privateDirectMessage,
            tags: [["p", alice.publicKeyHex]],
            content: "id derivation check"
        )

        let rumor = try unsigned.asRumor()
        let signed = try EventSigner(keyPair: alice).sign(unsigned)

        // The id derives from the serialized content only, never the signature
        #expect(rumor.id == signed.id)
        #expect(rumor.sig.isEmpty)
        #expect(!signed.sig.isEmpty)
    }

    @Test("Group message rumor is unsigned")
    func groupMessageRumorIsUnsigned() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let giftWraps = try builder.createGroupMessage(
            content: "Group hello",
            to: [bob.publicKeyHex]
        )

        let unwrapped = try GiftWrap.unwrap(giftWrap: giftWraps[0], recipientKeyPair: bob)
        #expect(unwrapped.event.sig.isEmpty)
    }

    @Test("DirectMessage properties")
    func directMessageProperties() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: alice)
        let giftWrap = try builder.createMessageWithSelfCopy(
            content: "Test content",
            to: bob.publicKeyHex,
            subject: "Subject"
        ).recipientGiftWrap

        let parser = DirectMessageParser(keyPair: bob)
        let message = try parser.parse(giftWrap)

        #expect(message.id == message.rumorId)
        #expect(message.senderPubkey == alice.publicKeyHex)
        #expect(!message.rumorId.isEmpty)
    }

    @Test("Invalid gift wrap kind throws error")
    func invalidGiftWrapKind() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        // Create a regular text note (not a gift wrap)
        let signer = EventSigner(keyPair: alice)
        let textNote = try signer.signTextNote(content: "Not a gift wrap")

        let parser = DirectMessageParser(keyPair: bob)

        #expect(throws: NostrError.self) {
            _ = try parser.parse(textNote)
        }
    }
}
