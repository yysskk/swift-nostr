import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// A signer whose NIP-44 decryption always fails the way an unreachable remote signer does: the
/// request never got far enough to judge the event.
private struct UnreachableSigner: NostrSigning {
    let keyPair: KeyPair

    var publicKey: PublicKey {
        get async throws { keyPair.publicKey }
    }

    func sign(_ event: UnsignedEvent) async throws -> Event {
        throw RelayConnection.Error.timedOut
    }

    func sign(_ template: EventTemplate) async throws -> Event {
        throw RelayConnection.Error.timedOut
    }

    func nip44Encrypt(_ plaintext: String, to recipientPublicKey: PublicKey) async throws -> String {
        throw RelayConnection.Error.timedOut
    }

    func nip44Decrypt(_ ciphertext: String, from senderPublicKey: PublicKey) async throws -> String {
        throw RelayConnection.Error.timedOut
    }
}

@Suite("Direct Message Sequence Tests")
struct DirectMessageSequenceTests {

    private let relayURL = RelayURL("wss://relay.example.com")!

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
        return DirectMessageSequence(
            messagesOf: DirectMessagePayloadSequence(subscription: base, parser: DirectMessageParser(signer: signer)))
    }

    @Test("yields parsed messages and skips unparseable items")
    func yieldsParsedMessagesAndSkipsUnparseable() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let carol = KeyPair()

        // A message addressed to Bob, one addressed to Carol (undecryptable by
        // Bob), a plain text note, and a notice — only Bob's DM should emerge.
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKey, subject: "greetings")
        let toCarol = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi carol", to: carol.publicKey)
        let plainNote = EventSigner(keyPair: alice).sign(.textNote("public note"))

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
        #expect(received.first?.senderPublicKey == alice.publicKey)
        #expect(received.first?.recipientPublicKey == bob.publicKey)
        #expect(received.first?.subject == "greetings")
        #expect(received.first?.rumorID == toBob.rumor.id)
    }

    @Test("a signer that cannot attempt the read throws instead of dropping the message")
    func signerFailureThrowsRatherThanSkipping() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        // A message genuinely addressed to Bob. Bob's signer is unreachable, so the failure says
        // nothing about the event — treating it like a foreign wrap would consume the message from
        // the stream and leave the caller unable to notice, let alone resubscribe.
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKey)

        let sequence = makeSequence(
            items: [.event(relayURL: relayURL, event: toBob.recipientGiftWrap)],
            signer: UnreachableSigner(keyPair: bob)
        )

        await #expect(throws: RelayConnection.Error.timedOut) {
            for try await _ in sequence {
                Issue.record("the unreachable signer must not yield a message")
            }
        }
    }

    @Test("payloads surface a signer failure the same way")
    func payloadSignerFailureThrows() async throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKey)

        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        continuation.yield(.event(relayURL: relayURL, event: toBob.recipientGiftWrap))
        continuation.finish()
        let sequence = DirectMessagePayloadSequence(
            subscription: SubscriptionSequence(
                id: "sub_test", expectedRelays: [relayURL], stream: stream, onClose: {}),
            parser: DirectMessageParser(signer: UnreachableSigner(keyPair: bob))
        )

        await #expect(throws: RelayConnection.Error.timedOut) {
            for try await _ in sequence {
                Issue.record("the unreachable signer must not yield a payload")
            }
        }
    }

    @Test("a gift wrap sealed to someone else is skipped, and later messages still arrive")
    func foreignGiftWrapSkippedWithoutEndingTheStream() async throws {
        let alice = KeyPair()
        let bob = KeyPair()
        let carol = KeyPair()

        let toCarol = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi carol", to: carol.publicKey)
        let toBob = try await DirectMessageBuilder(signer: EventSigner(keyPair: alice))
            .createMessageWithSelfCopy(content: "hi bob", to: bob.publicKey)

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
        let bob = KeyPair()
        let sequence = makeSequence(items: [], recipient: bob)
        #expect(sequence.id == "sub_test")
        #expect(sequence.expectedRelays == [relayURL])
        await sequence.close()
    }

    @Test("messages.subscribe requires a signer")
    func directMessagesRequiresSigner() async throws {
        let client = NostrClient()
        await #expect(throws: NostrClient.Error.signerNotSet) {
            _ = try await client.messages.subscribe()
        }
    }

    @Test("messages.subscribe opens and closes a subscription")
    func directMessagesOpensAndClosesSubscription() async throws {
        let (client, _) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(String(repeating: "1", count: 64))

        let messages = try await client.messages.subscribe()
        #expect(await client.activeSubscriptionCount == 1)
        await messages.close()
        #expect(await client.activeSubscriptionCount == 0)
        await client.relays.disconnect()
    }

    @Test("messages.subscribe requests the gift wraps tagged to the signer, 100 by default or the given limit")
    func directMessagesRequestFilter() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let bob = KeyPair()
        await client.identity.setSigner(EventSigner(keyPair: bob))

        let byDefault = try await client.messages.subscribe()
        let limited = try await client.messages.subscribe(limit: 5)
        try await NIP42TestSupport.pollUntil {
            socket.sentTextFrames.filter { $0.hasPrefix("[\"REQ\"") }.count == 2
        }
        let filters = try socket.sentTextFrames.filter { $0.hasPrefix("[\"REQ\"") }.map { frame in
            let request = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [Any])
            #expect(request.count == 3)
            return try #require(request.last as? [String: Any])
        }

        #expect(filters.map { Set($0.keys) } == [["kinds", "#p", "limit"], ["kinds", "#p", "limit"]])
        #expect(filters.map { $0["kinds"] as? [Int] } == [[1059], [1059]])
        #expect(filters.map { $0["#p"] as? [String] } == [[bob.publicKey.hex], [bob.publicKey.hex]])
        #expect(filters.map { $0["limit"] as? Int } == [100, 5])
        await byDefault.close()
        await limited.close()
        await client.relays.disconnect()
    }
}
