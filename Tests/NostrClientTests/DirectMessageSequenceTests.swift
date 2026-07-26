import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// A signer whose NIP-44 decryption always fails the way an unreachable remote signer does: the
/// request never got far enough to judge the event.
private struct UnreachableSigner: NostrSigning {
    let keyPair: KeyPair

    var publicKey: String {
        get async throws { keyPair.publicKeyHex }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        throw NostrError.timeout
    }

    func nip44Encrypt(_ plaintext: String, to recipientPubkey: String) async throws -> String {
        throw NostrError.timeout
    }

    func nip44Decrypt(_ ciphertext: String, from senderPubkey: String) async throws -> String {
        throw NostrError.timeout
    }
}

@Suite("Direct Message Sequence Tests")
struct DirectMessageSequenceTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeSequence(
        items: [SubscriptionEvent],
        recipient: KeyPair
    ) -> DirectMessageSequence {
        makeSequence(items: items, signer: EventSigner(keyPair: recipient))
    }

    private func makeSequence(
        items: [SubscriptionEvent],
        signer: any NostrSigning
    ) -> DirectMessageSequence {
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        for item in items {
            continuation.yield(item)
        }
        continuation.finish()
        let base = SubscriptionSequence(
            id: "sub_test",
            expectedRelays: [relayURL],
            stream: stream,
            onClose: {}
        )
        return DirectMessageSequence(base: base, parser: DirectMessageParser(signer: signer))
    }

    @Test("yields parsed messages and skips unparseable items")
    func yieldsParsedMessagesAndSkipsUnparseable() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let carol = try KeyPair()

        // A message addressed to Bob, one addressed to Carol (undecryptable by
        // Bob), a plain text note, and a notice — only Bob's DM should emerge.
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKeyHex, subject: "greetings")
        let toCarol = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi carol", to: carol.publicKeyHex)
        let plainNote = try EventSigner(keyPair: alice).signTextNote(content: "public note")

        let sequence = makeSequence(
            items: [
                .notice(relayURL: relayURL, message: "hello"),
                .event(relayURL: relayURL, event: toCarol.recipientGiftWrap),
                .event(relayURL: relayURL, event: plainNote),
                .event(relayURL: relayURL, event: toBob.recipientGiftWrap),
                .eose(relayURL: relayURL),
            ],
            recipient: bob
        )

        var received: [DirectMessage] = []
        for try await message in sequence {
            received.append(message)
        }

        #expect(received.count == 1)
        #expect(received.first?.content == "hi bob")
        #expect(received.first?.senderPubkey == alice.publicKeyHex)
        #expect(received.first?.recipientPubkey == bob.publicKeyHex)
        #expect(received.first?.subject == "greetings")
        #expect(received.first?.rumorId == toBob.rumor.id)
    }

    @Test("a signer that cannot attempt the read throws instead of dropping the message")
    func signerFailureThrowsRatherThanSkipping() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        // A message genuinely addressed to Bob. Bob's signer is unreachable, so the failure says
        // nothing about the event — treating it like a foreign wrap would consume the message from
        // the stream and leave the caller unable to notice, let alone resubscribe.
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKeyHex)

        let sequence = makeSequence(
            items: [.event(relayURL: relayURL, event: toBob.recipientGiftWrap)],
            signer: UnreachableSigner(keyPair: bob)
        )

        await #expect(throws: NostrError.timeout) {
            for try await _ in sequence {
                Issue.record("the unreachable signer must not yield a message")
            }
        }
    }

    @Test("payloads surface a signer failure the same way")
    func payloadSignerFailureThrows() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKeyHex)

        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        continuation.yield(.event(relayURL: relayURL, event: toBob.recipientGiftWrap))
        continuation.finish()
        let sequence = DirectMessagePayloadSequence(
            base: SubscriptionSequence(
                id: "sub_test", expectedRelays: [relayURL], stream: stream, onClose: {}),
            parser: DirectMessageParser(signer: UnreachableSigner(keyPair: bob))
        )

        await #expect(throws: NostrError.timeout) {
            for try await _ in sequence {
                Issue.record("the unreachable signer must not yield a payload")
            }
        }
    }

    @Test("a gift wrap sealed to someone else is skipped, and later messages still arrive")
    func foreignGiftWrapSkippedWithoutEndingTheStream() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let carol = try KeyPair()

        let toCarol = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi carol", to: carol.publicKeyHex)
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKeyHex)

        // Carol's wrap fails to decrypt for Bob — routine on a shared gift-wrap stream, so it must
        // be skipped rather than ending the subscription before Bob's own message arrives.
        let sequence = makeSequence(
            items: [
                .event(relayURL: relayURL, event: toCarol.recipientGiftWrap),
                .event(relayURL: relayURL, event: toBob.recipientGiftWrap),
            ],
            recipient: bob
        )

        var received: [DirectMessage] = []
        for try await message in sequence {
            received.append(message)
        }

        #expect(received.map(\.content) == ["hi bob"])
    }

    @Test("exposes id, expectedRelays, and close")
    func exposesMetadata() async throws {
        let bob = try KeyPair()
        let sequence = makeSequence(items: [], recipient: bob)
        #expect(sequence.id == "sub_test")
        #expect(sequence.expectedRelays == [relayURL])
        await sequence.close()
    }

    @Test("directMessages(limit:) requires a signer")
    func directMessagesRequiresSigner() async throws {
        let client = NostrClient()
        await #expect(throws: NostrError.self) {
            _ = try await client.directMessages()
        }
    }

    @Test("directMessages(limit:) opens and closes a subscription")
    func directMessagesOpensAndClosesSubscription() async throws {
        let (client, _) = try await ConnectedClientFixture.make()
        try await client.setPrivateKey(String(repeating: "1", count: 64))

        let messages = try await client.directMessages()
        #expect(await client.activeSubscriptionCount == 1)
        await messages.close()
        #expect(await client.activeSubscriptionCount == 0)
        await client.disconnect()
    }
}
