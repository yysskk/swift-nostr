import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

/// The ``NostrMessaging`` conveniences are written once, in a protocol extension over the
/// primitives. Driving them through a stub that implements only the primitives shows what each one
/// builds and forwards — template, recipient, expiration, strategy, limit, and the defaults — and
/// which payload each parse helper accepts, without a relay pool.
@Suite("Messaging Capability Tests")
struct MessagingCapabilityTests {
    private let relayURL = RelayURL("wss://relay.example.com")!
    private let alice: KeyPair
    private let bob: KeyPair

    init() throws {
        alice = KeyPair()
        bob = KeyPair()
    }

    /// A stub whose signer is Bob, so gift wraps sealed to Bob open.
    private func makeStub(cannedGiftWraps: [Event] = []) -> RecordingMessagingCapabilities {
        RecordingMessagingCapabilities(
            signer: EventSigner(keyPair: bob), relayURL: relayURL, cannedGiftWraps: cannedGiftWraps)
    }

    /// Alice's builder, for gift wraps addressed to the stub.
    private var fromAlice: DirectMessageBuilder {
        DirectMessageBuilder(signer: EventSigner(keyPair: alice))
    }

    private func encryptedFile() throws -> EncryptedFile {
        EncryptedFile.encrypt(Data("file bytes".utf8))
    }

    /// The one send the stub recorded.
    private func onlySend(_ stub: RecordingMessagingCapabilities) async throws -> RecordingMessagingCapabilities.Send {
        let sends = await stub.sends
        #expect(sends.count == 1)
        return try #require(sends.first)
    }

    /// The NIP-44 error `operation` throws, so two failures to open a gift wrap can be compared.
    private func thrownError<T>(by operation: () async throws -> T) async -> SealedMessage.Error? {
        do {
            _ = try await operation()
            return nil
        } catch {
            return error as? SealedMessage.Error
        }
    }

    // MARK: - Send primitive's short forms

    @Test("sendGiftWrapped without an expiration forwards none and the strategy")
    func sendGiftWrappedShortFormWithoutExpiration() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let template = EventTemplate(kind: Event.Kind(rawValue: 30_999), content: "payload")

        let result = try await messaging.sendGiftWrapped(template, to: alice.publicKey, strategy: .firstAck)

        let recorded = try await onlySend(stub)
        #expect(recorded.template == template)
        #expect(recorded.recipientPublicKey == alice.publicKey)
        #expect(recorded.expiration == nil)
        #expect(recorded.strategy == .firstAck)
        #expect(result.rumor.publicKey == bob.publicKey)
        #expect(result.rumor.kind == Event.Kind(rawValue: 30_999))
    }

    @Test("sendGiftWrapped with an expiration forwards it, and the strategy defaults to nil")
    func sendGiftWrappedShortFormWithExpiration() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let expiry = Timestamp(rawValue: 2_000_000_000)

        try await messaging.sendGiftWrapped(
            EventTemplate(kind: Event.Kind(rawValue: 30_999)), to: alice.publicKey, expiration: expiry)

        let recorded = try await onlySend(stub)
        #expect(recorded.expiration == expiry)
        #expect(recorded.strategy == nil)
    }

    // MARK: - Send conveniences

    @Test("send gift-wraps a kind-14 template naming only the recipient, with the defaults")
    func sendDefaults() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub

        let result = try await messaging.send("hello", to: alice.publicKey)

        let recorded = try await onlySend(stub)
        #expect(recorded.template.kind == .privateDirectMessage)
        #expect(recorded.template.content == "hello")
        #expect(recorded.template.tags.map(\.rawArray) == [["p", alice.publicKey.hex]])
        #expect(recorded.recipientPublicKey == alice.publicKey)
        #expect(recorded.expiration == nil)
        #expect(recorded.strategy == nil)
        #expect(result.rumor.kind == .privateDirectMessage)
    }

    @Test("send carries the subject and reply tags and forwards expiration and strategy")
    func sendForwardsEverything() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let parent = EventID.fixture("parent")
        let expiry = Timestamp(rawValue: 2_000_000_000)

        try await messaging.send(
            "re: plans", to: alice.publicKey, subject: "plans", replyTo: parent, expiration: expiry,
            strategy: .quorum(2))

        let recorded = try await onlySend(stub)
        #expect(
            recorded.template.tags.map(\.rawArray) == [
                ["p", alice.publicKey.hex],
                ["subject", "plans"],
                ["e", parent.hex, "", "reply"],
            ])
        #expect(recorded.expiration == expiry)
        #expect(recorded.strategy == .quorum(2))
    }

    @Test("react gift-wraps a kind-7 template to the message's author, liking it by default")
    func reactDefaults() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let message = DirectMessage(
            rumorID: .fixture("message"), senderPublicKey: alice.publicKey, recipientPublicKey: bob.publicKey,
            content: "hi", createdAt: Timestamp(rawValue: 1_700_000_000))

        try await messaging.react(to: message)

        let recorded = try await onlySend(stub)
        #expect(recorded.template.kind == .reaction)
        #expect(recorded.template.content == "+")
        #expect(
            recorded.template.tags.map(\.rawArray) == [
                ["e", EventID.fixture("message").hex],
                ["p", alice.publicKey.hex],
                ["k", "14"],
            ])
        #expect(recorded.recipientPublicKey == alice.publicKey)
        #expect(recorded.expiration == nil)
        #expect(recorded.strategy == nil)
    }

    @Test("react forwards the reaction, expiration, and strategy")
    func reactForwardsEverything() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let message = DirectMessage(
            rumorID: .fixture("message"), senderPublicKey: alice.publicKey, recipientPublicKey: bob.publicKey,
            content: "hi", createdAt: Timestamp(rawValue: 1_700_000_000))
        let expiry = Timestamp(rawValue: 2_000_000_000)

        try await messaging.react(to: message, reaction: "🤙", expiration: expiry, strategy: .allSettled)

        let recorded = try await onlySend(stub)
        #expect(recorded.template.content == "🤙")
        #expect(recorded.expiration == expiry)
        #expect(recorded.strategy == .allSettled)
    }

    @Test("sendFile gift-wraps a kind-15 template with the URL and the file's keys, with the defaults")
    func sendFileDefaults() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let file = try encryptedFile()

        try await messaging.sendFile(
            url: "https://files.example.com/blob", mimeType: "image/jpeg", encryption: file, to: alice.publicKey)

        let recorded = try await onlySend(stub)
        #expect(recorded.template.kind == .fileMessage)
        #expect(recorded.template.content == "https://files.example.com/blob")
        #expect(
            recorded.template.tags.map(\.rawArray) == [
                ["p", alice.publicKey.hex],
                ["file-type", "image/jpeg"],
                ["encryption-algorithm", "aes-gcm"],
                ["decryption-key", file.key.base64EncodedString()],
                ["decryption-nonce", file.nonce.base64EncodedString()],
                ["x", file.encryptedSHA256],
                ["ox", file.originalSHA256],
            ])
        #expect(recorded.recipientPublicKey == alice.publicKey)
        #expect(recorded.expiration == nil)
        #expect(recorded.strategy == nil)
    }

    @Test("sendFile appends size, dimensions, and blurhash and forwards expiration and strategy")
    func sendFileForwardsEverything() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let file = try encryptedFile()
        let expiry = Timestamp(rawValue: 2_000_000_000)

        try await messaging.sendFile(
            url: "https://files.example.com/blob", mimeType: "image/png", encryption: file, size: 1024,
            dimensions: "640x480", blurhash: "LEHV6nWB2yk8", to: alice.publicKey, expiration: expiry,
            strategy: .firstAck)

        let recorded = try await onlySend(stub)
        #expect(
            recorded.template.tags.suffix(3).map(\.rawArray) == [
                ["size", "1024"],
                ["dim", "640x480"],
                ["blurhash", "LEHV6nWB2yk8"],
            ])
        #expect(recorded.template.tags.count == 10)
        #expect(recorded.expiration == expiry)
        #expect(recorded.strategy == .firstAck)
    }

    // MARK: - Parse conveniences

    @Test("each parse helper unwraps its own payload through parsePayload")
    func parseHelpersUnwrapTheirCase() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub
        let message = try await fromAlice.createMessageWithSelfCopy(content: "hi", to: bob.publicKey)
        let reaction = try await fromAlice.createReactionWithSelfCopy(
            reaction: "🤙", to: .fixture("message"), author: bob.publicKey, recipientPublicKey: bob.publicKey)
        let file = try await fromAlice.createFileMessageWithSelfCopy(
            url: "https://files.example.com/blob", mimeType: "image/jpeg", encryption: try encryptedFile(),
            to: bob.publicKey)

        let parsedMessage = try await messaging.parse(message.recipientGiftWrap)
        let parsedReaction = try await messaging.parseReaction(reaction.recipientGiftWrap)
        let parsedFile = try await messaging.parseFile(file.recipientGiftWrap)

        #expect(parsedMessage.content == "hi")
        #expect(parsedMessage.senderPublicKey == alice.publicKey)
        #expect(parsedReaction.content == "🤙")
        #expect(parsedReaction.messageID == .fixture("message"))
        #expect(parsedFile.url == "https://files.example.com/blob")
        #expect(
            await stub.parsedGiftWraps.map(\.id) == [
                message.recipientGiftWrap.id, reaction.recipientGiftWrap.id, file.recipientGiftWrap.id,
            ])
    }

    @Test("a parse helper handed another payload throws unexpectedKind with the payload's kind")
    func parseHelpersRejectOtherPayloads() async throws {
        let messaging: any NostrMessaging = makeStub()
        let message = try await fromAlice.createMessageWithSelfCopy(content: "hi", to: bob.publicKey)
        let reaction = try await fromAlice.createReactionWithSelfCopy(
            to: .fixture("message"), author: bob.publicKey, recipientPublicKey: bob.publicKey)

        await #expect(throws: DirectMessagePayload.Error.unexpectedKind(.reaction)) {
            try await messaging.parse(reaction.recipientGiftWrap)
        }
        await #expect(throws: DirectMessagePayload.Error.unexpectedKind(.privateDirectMessage)) {
            try await messaging.parseReaction(message.recipientGiftWrap)
        }
        await #expect(throws: DirectMessagePayload.Error.unexpectedKind(.privateDirectMessage)) {
            try await messaging.parseFile(message.recipientGiftWrap)
        }
    }

    @Test("a gift wrap that does not open throws what the dedicated parser throws")
    func parseHelpersPassUnwrapFailuresThrough() async throws {
        let messaging: any NostrMessaging = makeStub()
        let carol = KeyPair()
        // Sealed to Carol, so Bob's decryption fails.
        let foreign = try await fromAlice.createMessageWithSelfCopy(content: "hi", to: carol.publicKey)
        let parser = DirectMessageParser(signer: EventSigner(keyPair: bob))

        let expected = await thrownError { try await parser.parse(foreign.recipientGiftWrap) }

        #expect(expected != nil)
        #expect(await thrownError { try await messaging.parse(foreign.recipientGiftWrap) } == expected)
        #expect(await thrownError { try await messaging.parseReaction(foreign.recipientGiftWrap) } == expected)
        #expect(await thrownError { try await messaging.parseFile(foreign.recipientGiftWrap) } == expected)
    }

    // MARK: - Receiving

    @Test("subscribe keeps only the messages of payloads, with a default limit of 100")
    func subscribeKeepsMessagesOfPayloads() async throws {
        let message = try await fromAlice.createMessageWithSelfCopy(content: "first", to: bob.publicKey)
        let reaction = try await fromAlice.createReactionWithSelfCopy(
            to: message.rumor.id, author: alice.publicKey, recipientPublicKey: bob.publicKey)
        let file = try await fromAlice.createFileMessageWithSelfCopy(
            url: "https://files.example.com/blob", mimeType: "image/jpeg", encryption: try encryptedFile(),
            to: bob.publicKey)
        let foreign = try await fromAlice.createMessageWithSelfCopy(content: "not for bob", to: alice.publicKey)
        let second = try await fromAlice.createMessageWithSelfCopy(content: "second", to: bob.publicKey)
        let stub = makeStub(cannedGiftWraps: [
            message.recipientGiftWrap, reaction.recipientGiftWrap, file.recipientGiftWrap,
            foreign.recipientGiftWrap, second.recipientGiftWrap,
        ])
        let messaging: any NostrMessaging = stub

        let messages = try await messaging.subscribe()
        var contents: [String] = []
        for try await received in messages {
            contents.append(received.content)
        }

        #expect(contents == ["first", "second"])
        #expect(messages.id == "payloads_1")
        #expect(messages.expectedRelays == [relayURL])
        #expect(await stub.payloadLimits == [100])
        #expect(await stub.giftWrapLimits.isEmpty)
    }

    @Test("subscribe forwards its limit to payloads")
    func subscribeForwardsLimit() async throws {
        let stub = makeStub()
        let messaging: any NostrMessaging = stub

        _ = try await messaging.subscribe(limit: 5)

        #expect(await stub.payloadLimits == [5])
    }

    @Test("payloads() asks for 100 and delivers every payload kind")
    func payloadsShortForm() async throws {
        let message = try await fromAlice.createMessageWithSelfCopy(content: "hi", to: bob.publicKey)
        let reaction = try await fromAlice.createReactionWithSelfCopy(
            to: message.rumor.id, author: alice.publicKey, recipientPublicKey: bob.publicKey)
        let file = try await fromAlice.createFileMessageWithSelfCopy(
            url: "https://files.example.com/blob", mimeType: "image/jpeg", encryption: try encryptedFile(),
            to: bob.publicKey)
        let stub = makeStub(cannedGiftWraps: [
            message.recipientGiftWrap, reaction.recipientGiftWrap, file.recipientGiftWrap,
        ])
        let messaging: any NostrMessaging = stub

        var kinds: [String] = []
        for try await payload in try await messaging.payloads() {
            switch payload {
            case .message: kinds.append("message")
            case .reaction: kinds.append("reaction")
            case .file: kinds.append("file")
            }
        }

        #expect(kinds == ["message", "reaction", "file"])
        #expect(await stub.payloadLimits == [100])
    }

    @Test("giftWraps() asks for 100 and delivers the raw gift wraps")
    func giftWrapsShortForm() async throws {
        let message = try await fromAlice.createMessageWithSelfCopy(content: "hi", to: bob.publicKey)
        let stub = makeStub(cannedGiftWraps: [message.recipientGiftWrap])
        let messaging: any NostrMessaging = stub

        var ids: [EventID] = []
        for await event in try await messaging.giftWraps().events {
            ids.append(event.id)
        }

        #expect(ids == [message.recipientGiftWrap.id])
        #expect(await stub.giftWrapLimits == [100])
        #expect(await stub.payloadLimits.isEmpty)
    }
}
