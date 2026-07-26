import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-17 File Message Tests (kind 15)")
struct NIP17FileMessageTests {

    // MARK: - EncryptedFile

    @Test("encrypt produces a 256-bit key and 96-bit nonce and round-trips")
    func encryptDecryptRoundTrip() throws {
        let data = Data("attack at dawn".utf8)
        let encrypted = try EncryptedFile.encrypt(data)

        #expect(encrypted.key.count == 32)
        #expect(encrypted.nonce.count == 12)
        #expect(encrypted.encryptedSHA256.count == 64)  // hex-encoded SHA-256
        #expect(encrypted.originalSHA256.count == 64)
        #expect(encrypted.ciphertext != data)

        let decrypted = try EncryptedFile.decrypt(
            encrypted.ciphertext, key: encrypted.key, nonce: encrypted.nonce)
        #expect(decrypted == data)
    }

    @Test("decrypt with the wrong key fails")
    func decryptWrongKeyFails() throws {
        let encrypted = try EncryptedFile.encrypt(Data("secret".utf8))
        #expect(throws: NostrError.decryptionFailed) {
            _ = try EncryptedFile.decrypt(
                encrypted.ciphertext, key: Data(repeating: 0, count: 32), nonce: encrypted.nonce)
        }
    }

    @Test("decrypt rejects a truncated blob")
    func decryptTruncatedFails() {
        #expect(throws: NostrError.decryptionFailed) {
            _ = try EncryptedFile.decrypt(
                Data([1, 2, 3]), key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 12))
        }
    }

    // MARK: - Build

    @Test("a built file message carries the NIP-17 file tags")
    func fileMessageTags() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let encrypted = try EncryptedFile.encrypt(Data("x".utf8))

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(
            url: "https://files.example.com/1", mimeType: "image/png", encryption: encrypted,
            size: 123, dimensions: "640x480", blurhash: "LKO2", to: recipient.publicKeyHex)

        let rumor = result.rumor
        #expect(rumor.kind == .fileMessage)
        #expect(rumor.content == "https://files.example.com/1")
        #expect(rumor.sig.isEmpty)  // NIP-17 rumors are never signed
        #expect(rumor.referencedPubkeys == [recipient.publicKeyHex])
        #expect(rumor.firstTagValue(named: "file-type") == "image/png")
        #expect(rumor.firstTagValue(named: "encryption-algorithm") == "aes-gcm")
        #expect(rumor.firstTagValue(named: "decryption-key") == encrypted.key.base64EncodedString())
        #expect(rumor.firstTagValue(named: "decryption-nonce") == encrypted.nonce.base64EncodedString())
        #expect(rumor.firstTagValue(named: "x") == encrypted.encryptedSHA256)
        #expect(rumor.firstTagValue(named: "ox") == encrypted.originalSHA256)
        #expect(rumor.firstTagValue(named: "size") == "123")
        #expect(rumor.firstTagValue(named: "dim") == "640x480")
        #expect(rumor.firstTagValue(named: "blurhash") == "LKO2")
    }

    // MARK: - Round trip

    @Test("a file message round-trips: encrypt, send, parse, decrypt")
    func fileRoundTrip() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let original = Data("hello, this is a secret file".utf8)
        let encrypted = try EncryptedFile.encrypt(original)
        let url = "https://files.example.com/abc"

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(
            url: url, mimeType: "text/plain", encryption: encrypted,
            size: encrypted.ciphertext.count, to: recipient.publicKeyHex)

        let file = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseFileMessage(
            result.recipientGiftWrap)
        #expect(file.url == url)
        #expect(file.mimeType == "text/plain")
        #expect(file.senderPubkey == sender.publicKeyHex)
        #expect(file.encryptedSHA256 == encrypted.encryptedSHA256)
        #expect(file.originalSHA256 == encrypted.originalSHA256)
        #expect(file.size == encrypted.ciphertext.count)

        // The parsed key/nonce decrypt the (separately transmitted) blob back to the original.
        let decrypted = try EncryptedFile.decrypt(
            encrypted.ciphertext, key: file.decryptionKey, nonce: file.decryptionNonce)
        #expect(decrypted == original)

        // The self-copy decrypts with the sender's own key and yields the same file, guarding
        // against a wrong-key regression when wrapping the self-copy.
        let selfFile = try await DirectMessageParser(signer: EventSigner(keyPair: sender)).parseFileMessage(
            result.selfGiftWrap)
        #expect(selfFile.rumorId == file.rumorId)
        #expect(selfFile.url == url)
        let selfDecrypted = try EncryptedFile.decrypt(
            encrypted.ciphertext, key: selfFile.decryptionKey, nonce: selfFile.decryptionNonce)
        #expect(selfDecrypted == original)
    }

    @Test("parsePayload classifies a file message")
    func parsePayloadFile() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let encrypted = try EncryptedFile.encrypt(Data("x".utf8))

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(
            url: "https://files.example.com/1", mimeType: "image/png", encryption: encrypted,
            to: recipient.publicKeyHex)

        guard
            case .file(let file) = try await DirectMessageParser(signer: EventSigner(keyPair: recipient))
                .parsePayload(result.recipientGiftWrap)
        else {
            Issue.record("expected a file payload")
            return
        }
        #expect(file.url == "https://files.example.com/1")
    }

    @Test("parse and parseFileMessage reject the wrong inner kind")
    func crossParseRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let encrypted = try EncryptedFile.encrypt(Data("x".utf8))

        let message = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)
        let file = try await builder.createFileMessageWithSelfCopy(
            url: "u", mimeType: "image/png", encryption: encrypted, to: recipient.publicKeyHex)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        await #expect(throws: NostrError.self) { try await parser.parseFileMessage(message.recipientGiftWrap) }
        await #expect(throws: NostrError.self) { try await parser.parse(file.recipientGiftWrap) }
    }

    @Test("a file message without a decryption key is rejected")
    func fileWithoutKeyRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // Hand-built kind-15 rumor missing the decryption-key/nonce tags.
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .fileMessage,
            tags: [.pubkey(recipient.publicKeyHex), Tag(name: "file-type", values: ["image/png"])],
            content: "https://files.example.com/1"
        ).asRumor()
        let giftWrap = try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPubkey: recipient.publicKeyHex)

        await #expect(throws: NostrError.self) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseFileMessage(giftWrap)
        }
    }

    @Test("a file message with a wrong-length key is rejected")
    func fileWithBadKeyLengthRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        // A 16-byte key is valid base64 but not a 256-bit AES key.
        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: "https://files.example.com/1",
            key: Data(repeating: 0, count: 16), nonce: Data(repeating: 0, count: 12))

        await #expect(throws: NostrError.self) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseFileMessage(giftWrap)
        }
    }

    @Test("a file message with an empty URL is rejected")
    func fileWithEmptyURLRejected() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: "",
            key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 12))

        await #expect(throws: NostrError.self) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseFileMessage(giftWrap)
        }
    }

    /// Hand-builds a gift-wrapped kind-15 rumor with the given URL, key, and nonce, bypassing the
    /// builder so malformed values can be exercised.
    private static func wrapFileRumor(
        sender: KeyPair, recipient: KeyPair, url: String, key: Data, nonce: Data
    ) async throws -> Event {
        let rumor = try UnsignedEvent(
            pubkey: sender.publicKeyHex, kind: .fileMessage,
            tags: [
                .pubkey(recipient.publicKeyHex),
                Tag(name: "decryption-key", values: [key.base64EncodedString()]),
                Tag(name: "decryption-nonce", values: [nonce.base64EncodedString()]),
            ],
            content: url
        ).asRumor()
        return try await GiftWrap.wrap(
            event: rumor, signer: EventSigner(keyPair: sender), recipientPubkey: recipient.publicKeyHex)
    }

    @Test("a disappearing file message carries the expiration on the gift wrap")
    func fileWithExpiration() async throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let encrypted = try EncryptedFile.encrypt(Data("x".utf8))
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(
            url: "u", mimeType: "image/png", encryption: encrypted,
            to: recipient.publicKeyHex, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let file = try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).parseFileMessage(
            result.recipientGiftWrap)
        #expect(file.expiresAt == expiry)
    }
}
