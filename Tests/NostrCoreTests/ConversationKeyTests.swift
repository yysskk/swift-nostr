import Foundation
import Testing

@testable import NostrCore

@Suite("ConversationKey Tests")
struct ConversationKeyTests {

    // MARK: - Raw Bytes

    @Test("init(data:) accepts 32 bytes and keeps them")
    func acceptsThirtyTwoBytes() throws {
        let bytes = Data((0..<32).map { UInt8($0) })

        let key = try ConversationKey(data: bytes)

        #expect(key.data == bytes)
    }

    @Test("hex is the key's 64 lowercase hexadecimal digits")
    func hexEncodesTheBytes() throws {
        let key = try ConversationKey(data: Data((0..<32).map { UInt8($0) }))

        #expect(key.hex == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    }

    @Test("init(data:) rejects any length other than 32 bytes", arguments: [0, 16, 31, 33, 64])
    func rejectsWrongLength(byteCount: Int) {
        let bytes = Data(repeating: 0x01, count: byteCount)

        #expect(throws: NIP44Payload.Error.invalidConversationKey) {
            _ = try ConversationKey(data: bytes)
        }
    }

    // MARK: - Derivation

    // Agreement with the official `get_conversation_key` vectors is covered by
    // `NIP44VectorTests.conversationKey(_:)`, which derives every vector through this initializer.

    @Test("Derivation is symmetric between the two parties")
    func derivationIsSymmetric() throws {
        let alice = KeyPair()
        let bob = KeyPair()

        let fromAlice = try ConversationKey(privateKey: alice.privateKey, publicKey: bob.publicKey)
        let fromBob = try ConversationKey(privateKey: bob.privateKey, publicKey: alice.publicKey)

        #expect(fromAlice == fromBob)
    }

    @Test("Different peers derive different keys")
    func differentPeersDiffer() throws {
        let alice = KeyPair()

        let withBob = try ConversationKey(privateKey: alice.privateKey, publicKey: KeyPair().publicKey)
        let withCarol = try ConversationKey(privateKey: alice.privateKey, publicKey: KeyPair().publicKey)

        #expect(withBob != withCarol)
    }

    // MARK: - Random

    @Test("random() yields 32 bytes, and two calls differ")
    func randomKeys() {
        let first = ConversationKey.random()
        let second = ConversationKey.random()

        #expect(first.data.count == 32)
        #expect(second.data.count == 32)
        #expect(first != second)
    }

    @Test("A random key encrypts and decrypts a round trip")
    func randomKeyRoundTrips() throws {
        let key = ConversationKey.random()

        let encrypted = try NIP44Payload.encrypt("for the group", with: key)

        #expect(try encrypted.decrypt(with: key) == "for the group")
    }

    // MARK: - Redaction

    @Test("description, debugDescription, and dump never contain the key")
    func redaction() throws {
        let key = try ConversationKey(data: Data(repeating: 0xAB, count: 32))
        let hex = key.data.hexEncodedString()
        var dumped = ""
        dump(key, to: &dumped)

        for rendered in ["\(key)", String(reflecting: key), dumped] {
            #expect(!rendered.contains(hex))
            #expect(rendered.contains("<redacted>"))
        }
    }
}
