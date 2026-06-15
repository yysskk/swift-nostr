import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Direct Message Sequence Tests")
struct DirectMessageSequenceTests {

    private let relayURL = URL(string: "wss://relay.example.com")!

    private func makeSequence(
        items: [SubscriptionEvent],
        recipient: KeyPair
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
        return DirectMessageSequence(base: base, parser: DirectMessageParser(keyPair: recipient))
    }

    @Test("yields parsed messages and skips unparseable items")
    func yieldsParsedMessagesAndSkipsUnparseable() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let carol = try KeyPair()

        // A message addressed to Bob, one addressed to Carol (undecryptable by
        // Bob), a plain text note, and a notice — only Bob's DM should emerge.
        let toBob = try DirectMessageBuilder(keyPair: alice)
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKeyHex, subject: "greetings")
        let toCarol = try DirectMessageBuilder(keyPair: alice)
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
        for await message in sequence {
            received.append(message)
        }

        #expect(received.count == 1)
        #expect(received.first?.content == "hi bob")
        #expect(received.first?.senderPubkey == alice.publicKeyHex)
        #expect(received.first?.recipientPubkey == bob.publicKeyHex)
        #expect(received.first?.subject == "greetings")
        #expect(received.first?.rumorId == toBob.rumor.id)
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
        let client = NostrClient()
        try await client.setPrivateKey(String(repeating: "1", count: 64))

        let messages = try await client.directMessages()
        #expect(await client.activeSubscriptionCount == 1)
        await messages.close()
        #expect(await client.activeSubscriptionCount == 0)
    }
}
