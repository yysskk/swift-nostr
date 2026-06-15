import Crypto
import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("NIP-04 Encryption Tests")
struct NIP04Tests {
    // Cross-implementation vectors produced by go-nostr (via nostr-tools' nip04 test suite).
    let senderSecretHex = "91ba716fa9e7ea2fcbad360cf4f8e0d312f73984da63d90f524ad61a6a1e7dbe"
    let recipientSecretHex = "96f6fa197aa07477ab88f6981118466ae3a982faab8ad5db9d5426870c73d220"

    private func bytes(_ hex: String) throws -> Data {
        try #require(NWCHex.data(from: hex))
    }

    private func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    @Test("decrypts a known go-nostr ciphertext")
    func decryptKnownVector() throws {
        let recipientSecret = try bytes(recipientSecretHex)
        let senderPubkey = try KeyPair(privateKeyHex: senderSecretHex).publicKey
        let content = "zJxfaJ32rN5Dg1ODjOlEew==?iv=EV5bUjcc4OX2Km/zPp4ndQ=="

        let plaintext = try NIP04.decrypt(content, privateKey: recipientSecret, peerPubkeyXOnly: senderPubkey)

        #expect(plaintext == "nanana")
    }

    @Test("decrypts a known multi-block go-nostr ciphertext")
    func decryptKnownBigVector() throws {
        let recipientSecret = try bytes(recipientSecretHex)
        let senderPubkey = try KeyPair(privateKeyHex: senderSecretHex).publicKey
        let content =
            "6f8dMstm+udOu7yipSn33orTmwQpWbtfuY95NH+eTU1kArysWJIDkYgI2D25EAGIDJsNd45jOJ2NbVOhFiL3ZP/NWsTwXokk34iyHyA"
            + "/lkjzugQ1bHXoMD1fP/Ay4hB4al1NHb8HXHKZaxPrErwdRDb8qa/I6dXb/1xxyVvNQBHHvmsM5yIFaPwnCN1DZqXf2KbTA/Ekz7Hy"
            + "+7R+Sy3TXLQDFpWYqykppkXc7Fs0qSuPRyxz5+anuN0dxZa9GTwTEnBrZPbthKkNRrvZMdTGJ6WumOh9aUq8OJJWy9aOgsXvs7qjN"
            + "1UqcCqQqYaVnEOhCaqWNDsVtsFrVDj+SaLIBvCiomwF4C4nIgngJ5I69tx0UNI0q+ZnvOGQZ7m1PpW2NYP7Yw43HJNdeUEQAmdCPn"
            + "h/PJwzLTnIxHmQU7n7SPlMdV0SFa6H8y2HHvex697GAkyE5t8c2uO24OnqIwF1tR3blIqXzTSRl0GA6QvrSj2p4UtnWjvF7xT7RiI"
            + "EyTtgU/AsihTrXyXzWWZaIBJogpgw6erlZqWjCH7sZy/WoGYEiblobOAqMYxax6vRbeuGtoYksr/myX+x9rfLrYuoDRTw4woXOLmM"
            + "rrj+Mf0TbAgc3SjdkqdsPU1553rlSqIEZXuFgoWmxvVQDtekgTYyS97G81TDSK9nTJT5ilku8NVq2LgtBXGwsNIw/xekcOUzJke3"
            + "kpnFPutNaexR1VF3ohIuqRKYRGcd8ADJP2lfwMcaGRiplAmFoaVS1YUhQwYFNq9rMLf7YauRGV4BJg/t9srdGxf5RoKCvRo+XM/n"
            + "LxxysTR9MVaEP/3lDqjwChMxs+eWfLHE5vRWV8hUEqdrWNZV29gsx5nQpzJ4PARGZVu310pQzc6JAlc2XAhhFk6RamkYJnmCSMnb"
            + "/RblzIATBi2kNrCVAlaXIon188inB62rEpZGPkRIP7PUfu27S/elLQHBHeGDsxOXsBRo1gl3te+raoBHsxo6zvRnYbwdAQa5taDE"
            + "63eh+fT6kFI+xYmXNAQkU8Dp0MVhEh4JQI06Ni/AKrvYpC95TXXIphZcF+/Pv/vaGkhG2X9S3uhugwWK?iv=2vWkOQQi0WynNJz/aZ4k2g=="
        let expected = String(repeating: "z", count: 800)

        let plaintext = try NIP04.decrypt(content, privateKey: recipientSecret, peerPubkeyXOnly: senderPubkey)

        #expect(plaintext == expected)
    }

    @Test("encrypt then decrypt round-trips")
    func roundTrip() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let message = "the quick brown fox 🦊"

        let content = try NIP04.encrypt(message, privateKey: alice.privateKey, peerPubkeyXOnly: bob.publicKey)
        let decrypted = try NIP04.decrypt(content, privateKey: bob.privateKey, peerPubkeyXOnly: alice.publicKey)

        #expect(decrypted == message)
    }

    @Test("the shared key is the same from both sides")
    func sharedKeyIsSymmetric() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let aliceToBob = try NIP04.sharedKey(privateKey: alice.privateKey, peerPubkeyXOnly: bob.publicKey)
        let bobToAlice = try NIP04.sharedKey(privateKey: bob.privateKey, peerPubkeyXOnly: alice.publicKey)

        #expect(keyData(aliceToBob) == keyData(bobToAlice))
    }

    @Test("the IV is 16 bytes")
    func ivIsSixteenBytes() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let content = try NIP04.encrypt("hi", privateKey: alice.privateKey, peerPubkeyXOnly: bob.publicKey)
        let ivPart = try #require(content.components(separatedBy: "?iv=").last)

        #expect(Data(base64Encoded: ivPart)?.count == 16)
    }

    @Test("rejects content without an iv separator")
    func rejectsMissingIV() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        #expect(throws: NIP04.DecodingError.malformedContent) {
            try NIP04.decrypt("zJxfaJ32rN5Dg1ODjOlEew==", privateKey: bob.privateKey, peerPubkeyXOnly: alice.publicKey)
        }
    }

    @Test("rejects non-base64 ciphertext")
    func rejectsBadBase64() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        #expect(throws: NIP04.DecodingError.invalidBase64) {
            try NIP04.decrypt("not base64!?iv=also bad!", privateKey: bob.privateKey, peerPubkeyXOnly: alice.publicKey)
        }
    }

    @Test("rejects a base64 IV of the wrong length as malformed content")
    func rejectsWrongLengthIV() throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        // A valid-base64 ciphertext block paired with a base64 IV that decodes to 8 bytes, not 16.
        let content = "zJxfaJ32rN5Dg1ODjOlEew==?iv=AAAAAAAAAAA="

        #expect(throws: NIP04.DecodingError.malformedContent) {
            try NIP04.decrypt(content, privateKey: bob.privateKey, peerPubkeyXOnly: alice.publicKey)
        }
    }
}
