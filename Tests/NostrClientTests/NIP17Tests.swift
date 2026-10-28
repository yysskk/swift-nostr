import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-17 Private Direct Message Tests")
struct NIP17Tests {

    // MARK: - NIP-44 Encryption Tests

    @Test("NIP-44 encrypt and decrypt message")
    func nip44EncryptDecrypt() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let originalMessage = "Hello, Bob! This is a private message."

        // Alice encrypts a message for Bob
        let encrypted = try NIP44Payload.encrypt(originalMessage, for: bob.publicKey, using: alice)

        // Verify it's base64 encoded
        #expect(Data(base64Encoded: encrypted.base64) != nil)

        // Bob decrypts the message from Alice
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == originalMessage)
    }

    @Test("NIP-44 sender can decrypt own message")
    func nip44SenderDecrypt() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let originalMessage = "Hello, Bob!"

        let encrypted = try NIP44Payload.encrypt(originalMessage, for: bob.publicKey, using: alice)

        // Alice can decrypt using Bob's public key (same shared secret)
        let decrypted = try encrypted.decrypt(from: bob.publicKey, using: alice)

        #expect(decrypted == originalMessage)
    }

    @Test("NIP-44 with special characters")
    func nip44SpecialCharacters() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let originalMessage = "Hello! 🎉 Special: <>&\"'日本語中文한국어"

        let encrypted = try NIP44Payload.encrypt(originalMessage, for: bob.publicKey, using: alice)
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == originalMessage)
    }

    @Test("NIP-44 with long message")
    func nip44LongMessage() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let originalMessage = String(repeating: "A", count: 10000)

        let encrypted = try NIP44Payload.encrypt(originalMessage, for: bob.publicKey, using: alice)
        let decrypted = try encrypted.decrypt(from: alice.publicKey, using: bob)

        #expect(decrypted == originalMessage)
    }

    @Test("NIP-44 version check")
    func nip44VersionCheck() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let encrypted = try NIP44Payload.encrypt("test", for: bob.publicKey, using: alice)
        let payload = Data(base64Encoded: encrypted.base64)!

        // First byte should be version 2
        #expect(payload[0] == 2)
    }

    // MARK: - Gift Wrap Tests

    @Test("Gift wrap and unwrap")
    func giftWrapUnwrap() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        // Alice wraps a note for Bob
        let wrapped = try await GiftWrap.wrap(
            .textNote("Secret message"),
            signer: EventSigner(keyPair: alice),
            to: bob.publicKey
        )

        // Verify it's a gift wrap event
        #expect(wrapped.kind == .giftWrap)

        // Verify the p tag points to Bob
        #expect(wrapped.referencedPublicKeys == [bob.publicKey])

        // Bob unwraps the event
        let unwrapped = try await GiftWrap.unwrap(giftWrap: wrapped, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPublicKey == alice.publicKey)
        #expect(unwrapped.event.content == "Secret message")
    }

    @Test("Gift wrap uses ephemeral key")
    func giftWrapEphemeralKey() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let wrapped = try await GiftWrap.wrap(
            .textNote("Test"),
            signer: EventSigner(keyPair: alice),
            to: bob.publicKey
        )

        // The gift wrap public key should NOT be Alice's public key (it's ephemeral)
        #expect(wrapped.publicKey != alice.publicKey)
    }

    @Test("wrap authors the rumor under the signer's key")
    func giftWrapAuthorsRumorUnderSigner() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let template = EventTemplate(kind: .privateDirectMessage, tags: [.publicKey(bob.publicKey)], content: "hi")

        let wrapped = try await GiftWrap.wrap(template, signer: EventSigner(keyPair: alice), to: bob.publicKey)
        let unwrapped = try await GiftWrap.unwrap(giftWrap: wrapped, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPublicKey == alice.publicKey)
        #expect(unwrapped.event.publicKey == alice.publicKey)
        #expect(unwrapped.event.id == UnsignedEvent(template, publicKey: alice.publicKey).computedID)
        #expect(unwrapped.event.createdAt == template.createdAt)
        #expect(unwrapped.event.signature == nil)
    }

    @Test("wrapping the same template twice yields one rumor id in distinct wraps")
    func giftWrapSameTemplateSharesRumorID() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let signer = EventSigner(keyPair: alice)
        let template = EventTemplate.textNote("twice")

        let forBob = try await GiftWrap.wrap(template, signer: signer, to: bob.publicKey)
        let forAlice = try await GiftWrap.wrap(template, signer: signer, to: alice.publicKey)
        let bobRumor = try await GiftWrap.unwrap(giftWrap: forBob, recipient: EventSigner(keyPair: bob)).event
        let aliceRumor = try await GiftWrap.unwrap(giftWrap: forAlice, recipient: signer).event

        #expect(bobRumor.id == aliceRumor.id)
        #expect(forBob.id != forAlice.id)
        #expect(forBob.publicKey != forAlice.publicKey)
    }

    @Test("wrap sets the expiration on the outer wrap, not the rumor")
    func giftWrapExpirationOnOuterWrap() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let expiry = Timestamp(rawValue: 2_000_000_000)

        let wrapped = try await GiftWrap.wrap(
            .textNote("fleeting"), signer: EventSigner(keyPair: alice), to: bob.publicKey, expiration: expiry)
        let unwrapped = try await GiftWrap.unwrap(giftWrap: wrapped, recipient: EventSigner(keyPair: bob))

        #expect(wrapped.expiration == expiry)
        #expect(unwrapped.event.expiration == nil)
    }

    // MARK: - Direct Message Tests

    @Test("Create and parse direct message")
    func directMessageRoundTrip() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let giftWrap = try await builder.createMessageWithSelfCopy(
            content: "Hello Bob!",
            to: bob.publicKey,
            subject: "Test Subject"
        ).recipientGiftWrap

        // Verify it's a gift wrap
        #expect(giftWrap.kind == .giftWrap)

        // Bob parses the message
        let parser = DirectMessageParser(signer: EventSigner(keyPair: bob))
        let message = try #require(await parser.open(giftWrap).message)

        #expect(message.content == "Hello Bob!")
        #expect(message.senderPublicKey == alice.publicKey)
        #expect(message.subject == "Test Subject")
    }

    @Test("Direct message with reply")
    func directMessageReply() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))

        // First message
        let firstMessage = try await builder.createMessageWithSelfCopy(
            content: "First message",
            to: bob.publicKey
        ).recipientGiftWrap

        let parser = DirectMessageParser(signer: EventSigner(keyPair: bob))
        let parsedFirst = try #require(await parser.open(firstMessage).message)

        // Reply to first message
        let bobBuilder = DirectMessageBuilder(signer: EventSigner(keyPair: bob))
        let reply = try await bobBuilder.createMessageWithSelfCopy(
            content: "Reply to first",
            to: alice.publicKey,
            replyTo: parsedFirst.rumorID
        ).recipientGiftWrap

        let aliceParser = DirectMessageParser(signer: EventSigner(keyPair: alice))
        let parsedReply = try #require(await aliceParser.open(reply).message)

        #expect(parsedReply.content == "Reply to first")
        #expect(parsedReply.replyTo == parsedFirst.rumorID)
    }

    @Test("Group message creates multiple gift wraps")
    func groupMessage() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let charlie = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let giftWraps = try await builder.createGroupMessage(
            content: "Hello everyone!",
            to: [bob.publicKey, charlie.publicKey],
            subject: "Group Chat"
        )

        // Should create 3 gift wraps: one for bob, one for charlie, one for alice (sender)
        #expect(giftWraps.count == 3)

        // Bob can parse his copy
        let bobParser = DirectMessageParser(signer: EventSigner(keyPair: bob))
        let bobMessage = try #require(await bobParser.open(giftWraps[0]).message)
        #expect(bobMessage.content == "Hello everyone!")

        // Charlie can parse his copy
        let charlieParser = DirectMessageParser(signer: EventSigner(keyPair: charlie))
        let charlieMessage = try #require(await charlieParser.open(giftWraps[1]).message)
        #expect(charlieMessage.content == "Hello everyone!")

        // Alice can parse her copy
        let aliceParser = DirectMessageParser(signer: EventSigner(keyPair: alice))
        let aliceMessage = try #require(await aliceParser.open(giftWraps[2]).message)
        #expect(aliceMessage.content == "Hello everyone!")
    }

    // MARK: - Self-Copy Tests

    @Test("Self-copy shares one unsigned rumor across both gift wraps")
    func selfCopySharesRumor() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let result = try await builder.createMessageWithSelfCopy(
            content: "Hello Bob!",
            to: bob.publicKey,
            subject: "Test Subject"
        )

        // The rumor is an unsigned kind 14 with a computed id
        #expect(result.rumor.kind == .privateDirectMessage)
        #expect(result.rumor.signature == nil)

        // Each wrap is addressed to its own recipient
        #expect(result.recipientGiftWrap.referencedPublicKeys == [bob.publicKey])
        #expect(result.selfGiftWrap.referencedPublicKeys == [alice.publicKey])

        // Bob unwraps the recipient copy, Alice unwraps the self-copy — same rumor
        let bobUnwrapped = try await GiftWrap.unwrap(
            giftWrap: result.recipientGiftWrap, recipient: EventSigner(keyPair: bob))
        let aliceUnwrapped = try await GiftWrap.unwrap(
            giftWrap: result.selfGiftWrap, recipient: EventSigner(keyPair: alice))

        #expect(bobUnwrapped.event.id == result.rumor.id)
        #expect(aliceUnwrapped.event.id == result.rumor.id)
        #expect(bobUnwrapped.event.content == "Hello Bob!")
        #expect(aliceUnwrapped.event.content == "Hello Bob!")
        #expect(bobUnwrapped.senderPublicKey == alice.publicKey)
        #expect(aliceUnwrapped.senderPublicKey == alice.publicKey)
    }

    @Test("A message whose p tag is not a canonical hex key is rejected")
    func messageWithMalformedRecipientRejected() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let template = EventTemplate(
            kind: .privateDirectMessage,
            tags: [Event.Tag(name: .publicKey, values: [bob.publicKey.hex.uppercased()])], content: "hi"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: alice), to: bob.publicKey)

        await #expect(throws: DirectMessagePayload.Error.invalidRecipient) {
            try await DirectMessageParser(signer: EventSigner(keyPair: bob)).open(giftWrap)
        }
    }

    @Test("A reply marker whose event id is not canonical hex leaves replyTo nil")
    func messageWithMalformedReplyMarker() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let template = EventTemplate(
            kind: .privateDirectMessage,
            tags: [.publicKey(bob.publicKey), Event.Tag(name: .event, values: ["not-an-id", "", "reply"])],
            content: "hi"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: alice), to: bob.publicKey)

        let message = try #require(await DirectMessageParser(signer: EventSigner(keyPair: bob)).open(giftWrap).message)

        #expect(message.replyTo == nil)
        #expect(message.recipientPublicKey == bob.publicKey)
        #expect(message.content == "hi")
    }

    @Test("Self-copy parses identically for sender and recipient")
    func selfCopyParsesOnBothSides() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let result = try await builder.createMessageWithSelfCopy(
            content: "Hello again",
            to: bob.publicKey,
            subject: "Subject",
            replyTo: EventID(String(repeating: "d", count: 64))!
        )

        let bobPayload = try await DirectMessageParser(signer: EventSigner(keyPair: bob)).open(result.recipientGiftWrap)
        let alicePayload = try await DirectMessageParser(signer: EventSigner(keyPair: alice)).open(result.selfGiftWrap)
        let bobMessage = try #require(bobPayload.message)
        let aliceMessage = try #require(alicePayload.message)

        // The rumor id is the echo-matching key on both sides
        #expect(bobMessage.rumorID == result.rumor.id)
        #expect(aliceMessage.rumorID == result.rumor.id)
        #expect(aliceMessage.content == bobMessage.content)
        #expect(aliceMessage.subject == bobMessage.subject)
        #expect(aliceMessage.replyTo == bobMessage.replyTo)
        #expect(aliceMessage.senderPublicKey == alice.publicKey)
        #expect(aliceMessage.recipientPublicKey == bob.publicKey)
    }

    @Test("Rumor id matches the id the signing path would produce")
    func rumorIDMatchesSignedID() throws {
        let alice = KeyPair()

        let unsigned = UnsignedEvent(
            publicKey: alice.publicKey,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .privateDirectMessage,
            tags: [.publicKey(alice.publicKey)],
            content: "id derivation check"
        )

        let rumor = unsigned.asRumor()
        let signed = try EventSigner(keyPair: alice).sign(unsigned)

        // The id derives from the serialized content only, never the signature
        #expect(rumor.id == signed.id)
        #expect(rumor.signature == nil)
        #expect(signed.signature != nil)
    }

    @Test("Group message rumor is unsigned")
    func groupMessageRumorIsUnsigned() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let giftWraps = try await builder.createGroupMessage(
            content: "Group hello",
            to: [bob.publicKey]
        )

        let unwrapped = try await GiftWrap.unwrap(giftWrap: giftWraps[0], recipient: EventSigner(keyPair: bob))
        #expect(unwrapped.event.signature == nil)
    }

    @Test("DirectMessage properties")
    func directMessageProperties() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: alice))
        let giftWrap = try await builder.createMessageWithSelfCopy(
            content: "Test content",
            to: bob.publicKey,
            subject: "Subject"
        ).recipientGiftWrap

        let parser = DirectMessageParser(signer: EventSigner(keyPair: bob))
        let message = try #require(await parser.open(giftWrap).message)

        #expect(message.id == message.rumorID)
        #expect(message.senderPublicKey == alice.publicKey)
    }

    @Test("Invalid gift wrap kind throws error")
    func invalidGiftWrapKind() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        // Create a regular text note (not a gift wrap)
        let signer = EventSigner(keyPair: alice)
        let textNote = signer.sign(.textNote("Not a gift wrap"))

        let parser = DirectMessageParser(signer: EventSigner(keyPair: bob))

        await #expect(throws: GiftWrap.Error.unexpectedKind(.textNote)) {
            _ = try await parser.open(textNote)
        }
    }

    @Test("open rejects a rumor that is not a message, reaction, or file")
    func openRejectsOtherKinds() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let template = EventTemplate(kind: .textNote, content: "hi")
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: alice), to: bob.publicKey)

        await #expect(throws: DirectMessagePayload.Error.unexpectedKind(.textNote)) {
            try await DirectMessageParser(signer: EventSigner(keyPair: bob)).open(giftWrap)
        }
    }
}
