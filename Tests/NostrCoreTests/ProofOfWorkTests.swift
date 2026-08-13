import Foundation
import NostrCore
import Testing

@Suite("NIP-13 Proof of Work Tests")
struct ProofOfWorkTests {

    // MARK: - Official Spec Vector

    /// The example event from the NIP-13 spec. Its id begins `000006d8…`, which is 21 leading zero
    /// bits, and it commits to a target of 20.
    /// https://github.com/nostr-protocol/nips/blob/master/13.md
    private var specEvent: Event {
        Event(
            id: "000006d8c378af1779d2feebc7603a125d99eca0ccf1085959b307f64e5dd358",
            pubkey: "a48380f4cfcc1ad5378294fcac36439770f9c878dd880ffa94bb74ea54a6f243",
            createdAt: 1_651_794_653,
            kind: 1,
            tags: [["nonce", "776797", "20"]],
            content: "It's just me mining my own business",
            sig:
                "284622fc0a3f4f1303455d5175f7ba962a3300d136085b9566801bc2e0699de0c7e31e44c81fb40ad9049173742e904713c3594a1da0fc5d2382a25c11aba977"
        )
    }

    @Test("spec example event has the difficulty stated by NIP-13")
    func specVectorDifficulty() {
        // 000006… = five zero nibbles (20 bits) then 0b0110 (one more leading zero) = 21 bits.
        #expect(ProofOfWork.difficulty(ofHexId: specEvent.id) == 21)
    }

    @Test("spec example event validates at its committed target but not above it")
    func specVectorValidation() {
        // Committed target is 20 and the id clears 21 bits, so it validates through 20.
        #expect(ProofOfWork.validate(event: specEvent, minimumDifficulty: 20))
        // One above the commitment fails even though the id itself would clear 21 bits — the
        // commitment, not the lucky id, is what a validator trusts.
        #expect(!ProofOfWork.validate(event: specEvent, minimumDifficulty: 21))
    }

    @Test("spec example event has a valid signature")
    func specVectorSignatureVerifies() throws {
        #expect(try specEvent.verify())
    }

    // MARK: - Difficulty Edges

    @Test("a fully-zero 64-char id is 256 bits")
    func difficultyAllZeros() {
        #expect(ProofOfWork.difficulty(ofHexId: String(repeating: "0", count: 64)) == 256)
    }

    @Test("the first non-zero nibble sets the leading-zero count")
    func difficultyNibbleTable() {
        #expect(ProofOfWork.difficulty(ofHexId: "f00000") == 0)
        #expect(ProofOfWork.difficulty(ofHexId: "700000") == 1)
        #expect(ProofOfWork.difficulty(ofHexId: "100000") == 3)
        #expect(ProofOfWork.difficulty(ofHexId: "0f0000") == 4)
    }

    @Test("an empty id is zero difficulty")
    func difficultyEmpty() {
        #expect(ProofOfWork.difficulty(ofHexId: "") == 0)
    }

    @Test("counting stops at the first non-hex character")
    func difficultyStopsAtNonHex() {
        #expect(ProofOfWork.difficulty(ofHexId: "00zz") == 8)
    }

    /// `Character.hexDigitValue` is non-nil for the Halfwidth and Fullwidth Forms of the hex
    /// digits, so an id of fullwidth zeros counted as a fully-mined one. A real event id is
    /// ASCII — the fullwidth spelling can only come from something crafted to look mined.
    @Test("fullwidth digits are not hex digits")
    func difficultyRejectsFullwidthDigits() {
        // U+FF10 FULLWIDTH DIGIT ZERO, 64 of them: the shape of a maximally-mined id.
        #expect(ProofOfWork.difficulty(ofHexId: String(repeating: "０", count: 64)) == 0)
        // Counting stops there rather than continuing past it.
        #expect(ProofOfWork.difficulty(ofHexId: "00０0") == 8)
        // U+FF41 FULLWIDTH LATIN SMALL LETTER A and U+FF21 its uppercase.
        #expect(ProofOfWork.difficulty(ofHexId: "00ａ") == 8)
        #expect(ProofOfWork.difficulty(ofHexId: "00Ａ") == 8)
    }

    /// A client that filters on proof of work before verifying — the natural order, since the
    /// hash is the cheap check — would otherwise accept a crafted event as maximally mined.
    @Test("an event whose id is fullwidth zeros does not validate")
    func validateRejectsFullwidthDigits() {
        let event = Event(
            id: String(repeating: "０", count: 64),
            pubkey: "a48380f4cfcc1ad5378294fcac36439770f9c878dd880ffa94bb74ea54a6f243",
            createdAt: 1_651_794_653,
            kind: 1,
            tags: [["nonce", "1", "256"]],
            content: "not actually mined",
            sig: String(repeating: "ab", count: 64)
        )

        #expect(!ProofOfWork.validate(event: event, minimumDifficulty: 1))
    }

    @Test("uppercase ASCII hex is still counted")
    func difficultyAcceptsUppercaseASCII() {
        #expect(ProofOfWork.difficulty(ofHexId: "00F0") == 8)
        #expect(ProofOfWork.difficulty(ofHexId: "000A") == 12)
    }

    // MARK: - Mining

    private func testSigner() throws -> EventSigner {
        try EventSigner(
            privateKeyHex: "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        )
    }

    private func unsignedNote(for signer: EventSigner, tags: [Event.Tag] = []) -> UnsignedEvent {
        UnsignedEvent(
            pubkey: signer.publicKey,
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: tags,
            content: "proof of work"
        )
    }

    @Test("mining reaches the requested difficulty and produces a signable, valid event", arguments: [8, 12])
    func mineMeetsDifficulty(_ difficulty: Int) async throws {
        let signer = try testSigner()
        let mined = try await ProofOfWork.mine(event: unsignedNote(for: signer), difficulty: difficulty)

        // Exactly one nonce tag, committing to the requested target.
        let nonceTags = mined.tags.filter { $0.first == "nonce" }
        #expect(nonceTags.count == 1)
        #expect(nonceTags.first?.count == 3)
        #expect(nonceTags.first?[2] == String(difficulty))

        let signed = try signer.sign(mined)
        #expect(ProofOfWork.difficulty(ofHexId: signed.id) >= difficulty)
        #expect(try signed.verify())
        #expect(ProofOfWork.validate(event: signed, minimumDifficulty: difficulty))
    }

    @Test("mining replaces any pre-existing nonce tag")
    func mineReplacesExistingNonce() async throws {
        let signer = try testSigner()
        let seeded = unsignedNote(for: signer, tags: [.nonce("0", target: 4), .hashtag("nostr")])

        let mined = try await ProofOfWork.mine(event: seeded, difficulty: 8)

        let nonceTags = mined.tags.filter { $0.first == "nonce" }
        #expect(nonceTags.count == 1)
        #expect(nonceTags.first?[2] == "8")
        // Non-nonce tags are preserved.
        #expect(mined.tags.contains { $0.first == "t" && $0.dropFirst().first == "nostr" })
    }

    @Test("mining rejects a difficulty outside 0...256")
    func mineRejectsOutOfRangeDifficulty() async throws {
        let signer = try testSigner()
        await #expect(throws: NostrError.invalidData) {
            _ = try await ProofOfWork.mine(event: unsignedNote(for: signer), difficulty: 257)
        }
    }

    @Test("mining is cancellable")
    func mineIsCancellable() async throws {
        let signer = try testSigner()
        let note = unsignedNote(for: signer)

        let task = Task {
            // Difficulty 64 will not complete, so cancellation is the only way out.
            try await ProofOfWork.mine(event: note, difficulty: 64)
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    // MARK: - Signer Convenience

    @Test("sign(_:proofOfWork:) produces an event meeting the difficulty that verifies")
    func signWithProofOfWork() async throws {
        let signer = try testSigner()
        let signed = try await signer.sign(unsignedNote(for: signer), proofOfWork: 8)

        #expect(ProofOfWork.difficulty(ofHexId: signed.id) >= 8)
        #expect(try signed.verify())
        #expect(ProofOfWork.validate(event: signed, minimumDifficulty: 8))
    }

    // MARK: - Validation Edges

    @Test("a zero or negative minimum difficulty accepts any event")
    func validateAcceptsZeroMinimum() throws {
        let signer = try testSigner()
        let note = try signer.signTextNote(content: "no work")
        #expect(ProofOfWork.validate(event: note, minimumDifficulty: 0))
    }

    @Test("a lucky id without a commitment is rejected")
    func validateRejectsMissingCommitment() {
        // The id clears 21 bits, but there is no nonce tag to commit to it.
        let event = Event(
            id: specEvent.id,
            pubkey: specEvent.pubkey,
            createdAt: specEvent.createdAt,
            kind: 1,
            tags: [],
            content: specEvent.content,
            sig: specEvent.sig
        )
        #expect(!ProofOfWork.validate(event: event, minimumDifficulty: 20))
    }
}
