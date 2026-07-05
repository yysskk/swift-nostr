import Foundation
import Testing

@testable import NostrCore

/// Official NIP-44 v2 interoperability vectors from paulmillr/nip44.
///
/// https://github.com/nostr-protocol/nips/blob/master/44.md
/// https://raw.githubusercontent.com/paulmillr/nip44/main/nip44.vectors.json
///
/// These pin swift-nostr's on-wire output to the reference implementation shared by nostr-tools,
/// NDK, and rust-nostr. They exercise the ChaCha20 keystream in both directions: decrypting the
/// reference payload and re-encrypting with the vector's exact nonce to reproduce it byte for byte.
/// The long, cross-block-boundary vectors are the cases a counter-off-by-one keystream corrupts.
@Suite("NIP-44 Vector Tests")
struct NIP44VectorTests {
    /// A single `encrypt_decrypt` vector.
    struct EncryptDecryptVector {
        let sec1: String
        let sec2: String
        let nonce: String
        /// The plaintext as UTF-8 bytes in hex, embedded this way to keep multibyte characters
        /// unambiguous in source.
        let plaintextHex: String
        let payload: String

        var plaintext: String {
            String(decoding: Data(hexString: plaintextHex)!, as: UTF8.self)
        }
    }

    /// Representative `encrypt_decrypt` vectors covering a single byte, a short multibyte string,
    /// and two payloads whose plaintext crosses the 64-byte ChaCha20 block boundary.
    static let encryptDecryptVectors: [EncryptDecryptVector] = [
        // 1 byte: "a".
        EncryptDecryptVector(
            sec1: "0000000000000000000000000000000000000000000000000000000000000001",
            sec2: "0000000000000000000000000000000000000000000000000000000000000002",
            nonce: "0000000000000000000000000000000000000000000000000000000000000001",
            plaintextHex: "61",
            payload:
                "AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb"
        ),
        // 19 bytes of multibyte text (stays within one block).
        EncryptDecryptVector(
            sec1: "8f40e50a84a7462e2b8d24c28898ef1f23359fff50d8c509e6fb7ce06e142f9c",
            sec2: "b9b0a1e9cc20100c5faa3bbe2777303d25950616c4c6a3fa2e3e046f936ec2ba",
            nonce: "b20989adc3ddc41cd2c435952c0d59a91315d8c5218d5040573fc3749543acaf",
            plaintextHex: "6162696c697479f09fa49de79a8420c8bac8be",
            payload:
                "ArIJia3D3cQc0sQ1lSwNWakTFdjFIY1QQFc/w3SVQ6yvbG2S0x4Yu86QGwPTy7mP3961I1XqB6SFFTzqDZZavhxoWMj7mEVGMQIsh2RLWI5EYQaQDIePSnXPlzf7CIt+voTD"
        ),
        // 161 bytes: crosses several 64-byte blocks.
        EncryptDecryptVector(
            sec1: "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
            sec2: "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
            nonce: "a3e219242d85465e70adcd640b564b3feff57d2ef8745d5e7a0663b2dccceb54",
            plaintextHex:
                "f09f998820f09f998920f09f998a2030efb88fe283a32031efb88fe283a32032efb88fe283a32033efb88fe283a3"
                + "2034efb88fe283a32035efb88fe283a32036efb88fe283a32037efb88fe283a32038efb88fe283a32039efb88fe2"
                + "83a320f09f949f20506f776572d984d98fd984d98fd8b5d991d8a8d98fd984d98fd984d8b5d991d8a8d98fd8b1d8"
                + "b1d98b20e0a5a320e0a5a36820e0a5a320e0a5a3e58697",
            payload:
                "AqPiGSQthUZecK3NZAtWSz/v9X0u+HRdXnoGY7LczOtUf05aMF89q1FLwJvaFJYICZoMYgRJHFLwPiOHce7fuAc40kX0wXJvipyBJ9HzCOj7CgtnC1/cmPCHR3s5AIORmroBWglm1LiFMohv1FSPEbaBD51VXxJa4JyWpYhreSOEjn1wd0lMKC9b+osV2N2tpbs+rbpQem2tRen3sWflmCqjkG5VOVwRErCuXuPb5+hYwd8BoZbfCrsiAVLd7YT44dRtKNBx6rkabWfddKSLtreHLDysOhQUVOp/XkE7OzSkWl6sky0Hva6qJJ/V726hMlomvcLHjE41iKmW2CpcZfOedg=="
        ),
        // 224 bytes: crosses several 64-byte blocks.
        EncryptDecryptVector(
            sec1: "d5633530f5bcfebceb5584cfbbf718a30df0751b729dd9a789b9f30c0587d74e",
            sec2: "b74e6a341fb134127272b795a08b59250e5fa45a82a2eb4095e4ce9ed5f5e214",
            nonce: "e4cd5f7ce4eea024bc71b17ad456a986a74ac426c2c62b0a15eb5c5c8f888b68",
            plaintextHex:
                "d985d98fd986d98ed8a7d982d98ed8b4d98ed8a9d98f20d8b3d98fd8a8d98fd984d99020d8a7d990d8b3d992d8aa"
                + "d990d8aed992d8afd98ed8a7d985d99020d8a7d984d984d98fd991d8bad98ed8a9d99020d981d990d98a20d8a7d9"
                + "84d986d98fd991d8b8d98fd985d99020d8a7d984d992d982d98ed8a7d8a6d990d985d98ed8a9d99020d988d98ed9"
                + "81d990d98ad98520d98ad98ed8aed98fd8b5d98ed99120d8a7d984d8aad98ed991d8b7d992d8a8d990d98ad982d9"
                + "8ed8a7d8aad98f20d8a7d984d992d8add8a7d8b3d98fd988d8a8d990d98ad98ed991d8a9d98fd88c",
            payload:
                "AuTNX3zk7qAkvHGxetRWqYanSsQmwsYrChXrXFyPiItoIBsWu1CB+sStla2M4VeANASHxM78i1CfHQQH1YbBy24Tng7emYW44ol6QkFD6D8Zq7QPl+8L1c47lx8RoODEQMvNCbOk5ffUV3/AhONHBXnffrI+0025c+uRGzfqpYki4lBqm9iYU+k3Tvjczq9wU0mkVDEaM34WiQi30MfkJdRbeeYaq6kNvGPunLb3xdjjs5DL720d61Flc5ZfoZm+CBhADy9D9XiVZYLKAlkijALJur9dATYKci6OBOoc2SJS2Clai5hOVzR0yVeyHRgRfH9aLSlWW5dXcUxTo7qqRjNf8W5+J4jF4gNQp5f5d0YA4vPAzjBwSP/5bGzNDslKfcAH"
        ),
    ]

    /// Decrypting each reference payload must recover the exact plaintext. This fails when the
    /// keystream is offset by a block, which is why the cross-block vectors matter most.
    @Test("Decrypting official payloads recovers the plaintext", arguments: encryptDecryptVectors)
    func decryptMatchesPlaintext(_ vector: EncryptDecryptVector) throws {
        let recipient = try KeyPair(privateKeyHex: vector.sec2)
        let senderPubkey = try KeyPair(privateKeyHex: vector.sec1).publicKeyHex

        let decrypted = try SealedMessage(payload: vector.payload).open(from: senderPubkey, using: recipient)

        #expect(decrypted == vector.plaintext)
    }

    /// Sealing with the vector's exact nonce must reproduce the reference payload byte for byte.
    /// This locks the encrypt direction to the spec, not just the round-trip.
    @Test("Sealing with the vector nonce reproduces the official payload", arguments: encryptDecryptVectors)
    func encryptMatchesPayload(_ vector: EncryptDecryptVector) throws {
        let sender = try KeyPair(privateKeyHex: vector.sec1)
        let recipientPubkey = try KeyPair(privateKeyHex: vector.sec2).publicKeyHex
        let nonce = Data(hexString: vector.nonce)!

        let sealed = try SealedMessage.seal(
            vector.plaintext,
            for: recipientPubkey,
            using: sender,
            nonce: nonce
        )

        #expect(sealed.payload == vector.payload)
    }

    /// The ECDH + HKDF conversation-key derivation must match the reference implementation.
    @Test("Conversation key matches the official get_conversation_key vector")
    func conversationKeyMatchesVector() throws {
        // v2.valid.get_conversation_key[0].
        let sec1 = "315e59ff51cb9209768cf7da80791ddcaae56ac9775eb25b6dee1234bc5d2268"
        let pub2 = "c2f9d9948dc8c7c38321e4b85c8558872eafa0641cd269db76848a6073e69133"
        let expectedConversationKey = "3dfef0ce2a4d80a25e7a328accf73448ef67096f65f79588e358d9a0eb9013f1"

        let derived = try SealedMessage.conversationKeyHex(privateKeyHex: sec1, publicKeyHex: pub2)

        #expect(derived == expectedConversationKey)
    }
}
