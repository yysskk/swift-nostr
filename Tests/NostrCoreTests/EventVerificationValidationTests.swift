import Foundation
import NostrCore
import Testing

/// Verification hands the public key and signature to libsecp256k1, which parses fixed-width buffers
/// and would read past the end of a short one. Every input here is attacker-controlled in
/// practice: an event arrives from a relay with whatever `pubkey` and `sig` strings its author
/// chose. ``PublicKey`` and ``Signature`` only ever hold 32 and 64 bytes, so a structurally
/// invalid value is stopped when the event is decoded, before anything can verify it.
@Suite("Event Verification Input Validation")
struct EventVerificationValidationTests {
    private static let secretKeyHex = "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344"

    /// The JSON object of a genuine signed event, with `overrides` replacing its fields — what an
    /// attacker sends after taking a real event and rewriting part of it.
    private func eventJSON(overriding overrides: [String: Any] = [:]) throws -> Data {
        let event = try EventSigner(privateKeyHex: Self.secretKeyHex).sign(.textNote("gm"))
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        object.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test(
        "an event with a public key that is not 32 bytes does not decode",
        arguments: [
            "",  // zero bytes
            "ab",  // one byte
            String(repeating: "ab", count: 31),  // one byte short
            String(repeating: "ab", count: 33),  // one byte long, truncation would hide the excess
        ]
    )
    func wrongLengthPublicKeyIsRejected(publicKey: String) throws {
        let json = try eventJSON(overriding: ["pubkey": publicKey])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Event.self, from: json)
        }
    }

    @Test(
        "an event with a signature that is not 64 bytes does not decode",
        arguments: [
            String(repeating: "ab", count: 63),
            String(repeating: "ab", count: 65),
        ]
    )
    func wrongLengthSignatureIsRejected(sig: String) throws {
        let json = try eventJSON(overriding: ["sig": sig])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Event.self, from: json)
        }
    }

    @Test("an event with a non-hex public key or signature does not decode")
    func nonHexIsRejected() throws {
        for overrides in [["pubkey": String(repeating: "zz", count: 32)], ["sig": String(repeating: "zz", count: 64)]] {
            let json = try eventJSON(overriding: overrides)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(Event.self, from: json)
            }
        }
    }

    /// A public key longer than 32 bytes must not be silently truncated to its first 32: that would
    /// let one key be spelled arbitrarily many ways, and any allow/block list keyed on the public key
    /// could be bypassed while the signature still verified.
    @Test("a signed event does not decode under a padded spelling of its own public key")
    func paddedPublicKeyIsRejected() throws {
        let event = try EventSigner(privateKeyHex: Self.secretKeyHex).sign(.textNote("gm"))
        #expect(try event.verify())

        let json = try eventJSON(overriding: ["pubkey": event.publicKey.hex + "00"])

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Event.self, from: json)
        }
    }

    @Test("a decoded genuine event still verifies")
    func genuineEventVerifies() throws {
        let event = try JSONDecoder().decode(Event.self, from: try eventJSON())

        #expect(try event.verify())
    }

    @Test("an event with a signature from another key does not verify")
    func foreignSignatureDoesNotVerify() throws {
        let event = try EventSigner(privateKeyHex: Self.secretKeyHex).sign(.textNote("gm"))
        let other = try EventSigner(keyPair: try KeyPair()).sign(.textNote("gm"))
        let forged = Event(
            id: event.id, publicKey: event.publicKey, createdAt: event.createdAt, kind: event.kind,
            tags: event.tags, content: event.content, signature: other.signature)

        #expect(try forged.verify() == false)
    }

    @Test("an unsigned rumor does not verify")
    func rumorDoesNotVerify() throws {
        let rumor = try UnsignedEvent(publicKey: try KeyPair().publicKey, kind: .textNote, content: "gm").asRumor()

        #expect(rumor.signature == nil)
        #expect(throws: Event.VerificationError.missingSignature) {
            try rumor.verify()
        }
    }
}
