import Foundation
import NostrCore
import Testing

/// Verification must reject structurally invalid keys and signatures before handing them to
/// libsecp256k1, which parses fixed-width buffers and would otherwise read past the end of a
/// short one. Every input here is attacker-controlled in practice: an event arrives from a relay
/// with whatever `pubkey` and `sig` strings its author chose.
@Suite("Event Verification Input Validation")
struct EventVerificationValidationTests {
    /// Builds an event whose `id` is the genuine hash of its own serialization, so `verify()`
    /// gets past the id check and reaches the signature step — exactly what an attacker does.
    private func makeEventWithValidId(pubkey: String, sig: String) throws -> Event {
        let unsigned = UnsignedEvent(
            pubkey: pubkey,
            createdAt: 1,
            kind: .textNote,
            rawTags: [],
            content: "probe"
        )
        return Event(
            id: try unsigned.computedId,
            pubkey: pubkey,
            createdAt: unsigned.createdAt,
            kind: unsigned.kind,
            tags: unsigned.tags,
            content: unsigned.content,
            sig: sig
        )
    }

    private var wellFormedSignature: String {
        String(repeating: "ab", count: 64)
    }

    @Test(
        "verify rejects a pubkey that is not 32 bytes",
        arguments: [
            "",  // decodes to zero bytes
            "ab",  // one byte
            String(repeating: "ab", count: 31),  // one byte short
            String(repeating: "ab", count: 33),  // one byte long, truncation would hide the excess
        ]
    )
    func verifyRejectsWrongLengthPubkey(pubkey: String) throws {
        let event = try makeEventWithValidId(pubkey: pubkey, sig: wellFormedSignature)

        #expect(throws: NostrError.invalidPublicKey) {
            try event.verify()
        }
    }

    @Test(
        "verify rejects a signature that is not 64 bytes",
        arguments: [
            "",
            String(repeating: "ab", count: 63),
            String(repeating: "ab", count: 65),
        ]
    )
    func verifyRejectsWrongLengthSignature(sig: String) throws {
        let event = try makeEventWithValidId(
            pubkey: String(repeating: "cd", count: 32),
            sig: sig
        )

        #expect(throws: NostrError.invalidSignature) {
            try event.verify()
        }
    }

    @Test("verify still rejects non-hex pubkeys and signatures as invalid hex")
    func verifyRejectsNonHex() throws {
        let nonHexPubkey = try makeEventWithValidId(
            pubkey: String(repeating: "zz", count: 32),
            sig: wellFormedSignature
        )
        #expect(throws: NostrError.invalidHex) {
            try nonHexPubkey.verify()
        }

        let nonHexSignature = try makeEventWithValidId(
            pubkey: String(repeating: "cd", count: 32),
            sig: String(repeating: "zz", count: 64)
        )
        #expect(throws: NostrError.invalidHex) {
            try nonHexSignature.verify()
        }
    }

    /// A pubkey longer than 32 bytes must not be silently truncated to its first 32: that would
    /// let one key be spelled arbitrarily many ways, and any allow/block list keyed on the pubkey
    /// string could be bypassed while the signature still verified.
    @Test("a signed event does not verify under a padded spelling of its own pubkey")
    func paddedPubkeyDoesNotVerify() throws {
        let signer = try EventSigner(
            privateKeyHex: "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344"
        )
        let event = try signer.signTextNote(content: "gm")
        #expect(try event.verify())

        let padded = event.pubkey + "00"
        let forged = try makeEventWithValidId(pubkey: padded, sig: event.sig)

        #expect(throws: NostrError.invalidPublicKey) {
            try forged.verify()
        }
    }

    @Test("a genuine event still verifies")
    func genuineEventVerifies() throws {
        let signer = try EventSigner(
            privateKeyHex: "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344"
        )
        let event = try signer.signTextNote(content: "gm")

        #expect(try event.verify())
    }
}
