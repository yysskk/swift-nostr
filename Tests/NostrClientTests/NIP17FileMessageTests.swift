import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NIP-17 File Message Tests (kind 15)")
struct NIP17FileMessageTests {

    // MARK: - EncryptedFile

    @Test("encrypt produces a 256-bit key and 96-bit nonce and round-trips")
    func encryptDecryptRoundTrip() throws {
        let data = Data("attack at dawn".utf8)
        let encrypted = EncryptedFile.encrypt(data)

        #expect(encrypted.key.count == 32)
        #expect(encrypted.nonce.count == 12)
        #expect(encrypted.encryptedSHA256.count == 64)  // hex-encoded SHA-256
        #expect(encrypted.originalSHA256.count == 64)
        #expect(encrypted.ciphertext != data)

        let decrypted = try EncryptedFile.decrypt(
            encrypted.ciphertext, key: encrypted.key, nonce: encrypted.nonce)
        #expect(decrypted == data)
    }

    @Test("decrypt with the wrong key fails authentication")
    func decryptWrongKeyFails() throws {
        let encrypted = EncryptedFile.encrypt(Data("secret".utf8))
        #expect(throws: EncryptedFile.Error.authenticationFailed) {
            _ = try EncryptedFile.decrypt(
                encrypted.ciphertext, key: Data(repeating: 0, count: 32), nonce: encrypted.nonce)
        }
    }

    @Test("decrypt of a tampered blob fails authentication")
    func decryptTamperedFails() throws {
        let encrypted = EncryptedFile.encrypt(Data("secret".utf8))
        var tampered = encrypted.ciphertext
        tampered[tampered.startIndex] ^= 0x01
        #expect(throws: EncryptedFile.Error.authenticationFailed) {
            _ = try EncryptedFile.decrypt(tampered, key: encrypted.key, nonce: encrypted.nonce)
        }
    }

    @Test("decrypt rejects a truncated blob")
    func decryptTruncatedFails() {
        #expect(throws: EncryptedFile.Error.truncated) {
            _ = try EncryptedFile.decrypt(
                Data([1, 2, 3]), key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 12))
        }
    }

    @Test("decrypt rejects a key that is not 32 bytes")
    func decryptWrongKeyLengthFails() throws {
        let encrypted = EncryptedFile.encrypt(Data("secret".utf8))
        #expect(throws: EncryptedFile.Error.invalidKeyLength(16)) {
            _ = try EncryptedFile.decrypt(
                encrypted.ciphertext, key: encrypted.key.prefix(16), nonce: encrypted.nonce)
        }
    }

    @Test("decrypt rejects a nonce that is not 12 bytes")
    func decryptWrongNonceLengthFails() throws {
        let encrypted = EncryptedFile.encrypt(Data("secret".utf8))
        #expect(throws: EncryptedFile.Error.invalidNonceLength(16)) {
            _ = try EncryptedFile.decrypt(
                encrypted.ciphertext, key: encrypted.key, nonce: Data(repeating: 0, count: 16))
        }
    }

    // MARK: - FileAttachment

    @Test("an attachment built from an EncryptedFile takes its key, nonce, and both hashes")
    func attachmentFromEncryptedFile() throws {
        let encrypted = EncryptedFile.encrypt(Data("x".utf8))
        let url = try #require(URL(string: "https://files.example.com/1"))

        let attachment = FileAttachment(
            url: url, mimeType: "image/png", encryption: encrypted, size: 123, dimensions: "640x480",
            blurhash: "LKO2")

        #expect(attachment.url == url)
        #expect(attachment.mimeType == "image/png")
        #expect(attachment.decryptionKey == encrypted.key)
        #expect(attachment.decryptionNonce == encrypted.nonce)
        #expect(attachment.encryptedSHA256 == encrypted.encryptedSHA256)
        #expect(attachment.originalSHA256 == encrypted.originalSHA256)
        #expect(attachment.size == 123)
        #expect(attachment.dimensions == "640x480")
        #expect(attachment.blurhash == "LKO2")
    }

    @Test("an attachment decrypts the uploaded ciphertext back to the original")
    func attachmentDecrypts() throws {
        let original = Data("hello, this is a secret file".utf8)
        let encrypted = EncryptedFile.encrypt(original)
        let url = try #require(URL(string: "https://files.example.com/1"))
        let attachment = FileAttachment(url: url, mimeType: "text/plain", encryption: encrypted)

        #expect(try attachment.decrypt(encrypted.ciphertext) == original)
    }

    @Test("an attachment with the wrong key fails authentication")
    func attachmentWrongKeyFails() throws {
        let encrypted = EncryptedFile.encrypt(Data("secret".utf8))
        let url = try #require(URL(string: "https://files.example.com/1"))
        var attachment = FileAttachment(url: url, mimeType: "text/plain", encryption: encrypted)
        attachment.decryptionKey = Data(repeating: 0, count: 32)

        #expect(throws: EncryptedFile.Error.authenticationFailed) {
            _ = try attachment.decrypt(encrypted.ciphertext)
        }
    }

    // MARK: - Round trip

    @Test("a file message round-trips: encrypt, send, parse, decrypt")
    func fileRoundTrip() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let original = Data("hello, this is a secret file".utf8)
        let encrypted = EncryptedFile.encrypt(original)
        let url = try #require(URL(string: "https://files.example.com/abc"))
        let attachment = FileAttachment(
            url: url, mimeType: "text/plain", encryption: encrypted, size: encrypted.ciphertext.count,
            dimensions: "640x480", blurhash: "LKO2")

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(attachment, to: recipient.publicKey)

        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let file = try #require(await recipientParser.open(result.recipientGiftWrap).file)
        #expect(file.attachment == attachment)
        #expect(file.senderPublicKey == sender.publicKey)
        #expect(file.recipientPublicKey == recipient.publicKey)
        // The parsed key and nonce decrypt the (separately transmitted) blob back to the original.
        #expect(try file.attachment.decrypt(encrypted.ciphertext) == original)

        // The self-copy decrypts with the sender's own key and yields the same file, guarding
        // against a wrong-key regression when wrapping the self-copy.
        let senderParser = DirectMessageParser(signer: EventSigner(keyPair: sender))
        let selfFile = try #require(await senderParser.open(result.selfGiftWrap).file)
        #expect(selfFile.rumorID == file.rumorID)
        #expect(selfFile.attachment == attachment)
    }

    @Test("a hand-built file message without the optional tags opens with them nil")
    func fileWithoutOptionalTags() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let key = Data(repeating: 1, count: 32)
        let nonce = Data(repeating: 2, count: 12)

        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: "https://files.example.com/1", key: key, nonce: nonce)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let file = try #require(await parser.open(giftWrap).file)
        let url = try #require(URL(string: "https://files.example.com/1"))
        #expect(file.attachment == FileAttachment(url: url, decryptionKey: key, decryptionNonce: nonce))
    }

    @Test("messages.sendFile delivers an attachment that opens equal to the one sent")
    func clientSendFileRoundTrip() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let senderKey = KeyPair()
        try await client.identity.setSigner(EventSigner(keyPair: senderKey))
        let recipient = KeyPair()
        let encrypted = EncryptedFile.encrypt(Data("x".utf8))
        let url = try #require(URL(string: "https://files.example.com/1"))
        let attachment = FileAttachment(url: url, mimeType: "image/png", encryption: encrypted, size: 42)

        // Confirmed-absent DM relay lists: both copies fall back to the pool's relay without a
        // discovery fetch.
        await client.dmRelayListStore.markNoList(for: recipient.publicKey)
        await client.dmRelayListStore.markNoList(for: senderKey.publicKey)

        let result = try await PublishAckSupport.acknowledgingPublishes(2, on: socket) {
            try await client.messages.sendFile(attachment, to: recipient.publicKey)
        }
        await client.relays.disconnect()

        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let file = try #require(await recipientParser.open(result.message.recipientGiftWrap).file)
        #expect(file.attachment == attachment)
        let selfFile = try #require(await client.messages.open(result.message.selfGiftWrap).file)
        #expect(selfFile.attachment == attachment)
    }

    @Test("open classifies a file message")
    func openFile() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let encrypted = EncryptedFile.encrypt(Data("x".utf8))
        let url = try #require(URL(string: "https://files.example.com/1"))
        let attachment = FileAttachment(url: url, mimeType: "image/png", encryption: encrypted)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(attachment, to: recipient.publicKey)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        guard case .file(let file) = try await parser.open(result.recipientGiftWrap) else {
            Issue.record("expected a file payload")
            return
        }
        #expect(file.attachment.url == url)
    }

    @Test("a file message without a decryption key is rejected")
    func fileWithoutKeyRejected() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        // Hand-built kind-15 rumor missing the decryption-key/nonce tags.
        let template = EventTemplate(
            kind: .fileMessage,
            tags: [.publicKey(recipient.publicKey), Tag(name: "file-type", values: ["image/png"])],
            content: "https://files.example.com/1"
        )
        let giftWrap = try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: sender), to: recipient.publicKey)

        await #expect(throws: DirectMessagePayload.Error.invalidDecryptionKey) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    @Test("a file message with a wrong-length key is rejected")
    func fileWithBadKeyLengthRejected() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        // A 16-byte key is valid base64 but not a 256-bit AES key.
        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: "https://files.example.com/1",
            key: Data(repeating: 0, count: 16), nonce: Data(repeating: 0, count: 12))

        await #expect(throws: DirectMessagePayload.Error.invalidDecryptionKey) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    @Test("a file message with a wrong-length nonce is rejected")
    func fileWithBadNonceLengthRejected() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: "https://files.example.com/1",
            key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 16))

        await #expect(throws: DirectMessagePayload.Error.invalidDecryptionNonce) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    @Test(
        "a file message whose content is not an http(s) URL is rejected",
        arguments: ["", "http://[::1", "file:///etc/passwd", "data:text/plain,hi", "ftp://example.com/f", "https://"]
    )
    func fileWithInvalidURLRejected(url: String) async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        let giftWrap = try await Self.wrapFileRumor(
            sender: sender, recipient: recipient, url: url,
            key: Data(repeating: 0, count: 32), nonce: Data(repeating: 0, count: 12))

        await #expect(throws: DirectMessagePayload.Error.invalidFileURL) {
            try await DirectMessageParser(signer: EventSigner(keyPair: recipient)).open(giftWrap)
        }
    }

    /// Hand-builds a gift-wrapped kind-15 rumor with the given URL, key, and nonce, bypassing the
    /// builder so malformed values can be exercised.
    private static func wrapFileRumor(
        sender: KeyPair, recipient: KeyPair, url: String, key: Data, nonce: Data
    ) async throws -> Event {
        let template = EventTemplate(
            kind: .fileMessage,
            tags: [
                .publicKey(recipient.publicKey),
                Tag(name: "decryption-key", values: [key.base64EncodedString()]),
                Tag(name: "decryption-nonce", values: [nonce.base64EncodedString()]),
            ],
            content: url
        )
        return try await GiftWrap.wrap(
            template, signer: EventSigner(keyPair: sender), to: recipient.publicKey)
    }

    @Test("a disappearing file message carries the expiration on the gift wrap")
    func fileWithExpiration() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let encrypted = EncryptedFile.encrypt(Data("x".utf8))
        let expiry = Timestamp(rawValue: 1_700_000_000)

        let url = try #require(URL(string: "https://example.com/u"))
        let attachment = FileAttachment(url: url, mimeType: "image/png", encryption: encrypted)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createFileMessageWithSelfCopy(
            attachment, to: recipient.publicKey, expiration: expiry)

        #expect(result.recipientGiftWrap.expiration == expiry)
        let recipientParser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let file = try #require(await recipientParser.open(result.recipientGiftWrap).file)
        #expect(file.expiresAt == expiry)
    }
}
