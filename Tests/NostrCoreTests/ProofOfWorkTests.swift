import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("NIP-13 Proof of Work Tests")
struct ProofOfWorkTests {

    // MARK: - Official Spec Vector

    /// The example event from the NIP-13 spec. Its id begins `000006d8…`, which is 21 leading zero
    /// bits, and it commits to a target of 20.
    /// https://github.com/nostr-protocol/nips/blob/master/13.md
    private var specEvent: Event {
        get throws {
            Event(
                id: try EventID(hex: "000006d8c378af1779d2feebc7603a125d99eca0ccf1085959b307f64e5dd358"),
                publicKey: try PublicKey(hex: "a48380f4cfcc1ad5378294fcac36439770f9c878dd880ffa94bb74ea54a6f243"),
                createdAt: Timestamp(rawValue: 1_651_794_653),
                kind: 1,
                tags: [Event.Tag(name: .nonce, values: ["776797", "20"])],
                content: "It's just me mining my own business",
                signature:
                    try Signature(
                        hex:
                            "284622fc0a3f4f1303455d5175f7ba962a3300d136085b9566801bc2e0699de0c7e31e44c81fb40ad9049173742e904713c3594a1da0fc5d2382a25c11aba977"
                    )
            )
        }
    }

    @Test("spec example event has the difficulty stated by NIP-13")
    func specVectorDifficulty() throws {
        // 000006… = five zero nibbles (20 bits) then 0b0110 (one more leading zero) = 21 bits.
        #expect(ProofOfWork.difficulty(of: try specEvent.id) == 21)
    }

    @Test("spec example event validates at its committed target but not above it")
    func specVectorValidation() throws {
        let specEvent = try specEvent
        // Committed target is 20 and the id clears 21 bits, so it validates through 20.
        #expect(ProofOfWork.validate(event: specEvent, minimumDifficulty: 20))
        // One above the commitment fails even though the id itself would clear 21 bits — the
        // commitment, not the lucky id, is what a validator trusts.
        #expect(!ProofOfWork.validate(event: specEvent, minimumDifficulty: 21))
    }

    @Test("spec example event has a valid signature")
    func specVectorSignatureVerifies() throws {
        try specEvent.verify()
    }

    // MARK: - Difficulty Edges

    /// An id that starts with `prefix` and is padded with `f` — a nibble with no leading zeros —
    /// so the prefix alone decides the difficulty.
    private func id(startingWith prefix: String) throws -> EventID {
        try EventID(hex: prefix + String(repeating: "f", count: 64 - prefix.count))
    }

    @Test("a fully-zero id is 256 bits")
    func difficultyAllZeros() throws {
        #expect(ProofOfWork.difficulty(of: try EventID(hex: String(repeating: "0", count: 64))) == 256)
    }

    @Test("the first non-zero nibble sets the leading-zero count")
    func difficultyNibbleTable() throws {
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "f")) == 0)
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "7")) == 1)
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "1")) == 3)
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "0f")) == 4)
    }

    @Test("counting carries across byte boundaries and stops at the first set bit")
    func difficultyAcrossBytes() throws {
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "0080")) == 8)
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "00000001")) == 31)
        #expect(ProofOfWork.difficulty(of: try id(startingWith: "0000000010")) == 35)
    }

    // MARK: - Mining

    private func testSigner() throws -> EventSigner {
        try EventSigner(
            privateKeyHex: "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        )
    }

    private func unsignedNote(for signer: EventSigner, tags: [Event.Tag] = []) throws -> UnsignedEvent {
        UnsignedEvent(
            publicKey: signer.publicKey,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .textNote,
            tags: tags,
            content: "proof of work"
        )
    }

    @Test("mining reaches the requested difficulty and produces a signable, valid event", arguments: [8, 12])
    func mineMeetsDifficulty(_ difficulty: Int) async throws {
        let signer = try testSigner()
        let mined = try await ProofOfWork.mine(event: try unsignedNote(for: signer), difficulty: difficulty)

        // Exactly one nonce tag, committing to the requested target.
        let nonceTags = mined.tags.filter { $0.name == .nonce }
        #expect(nonceTags.count == 1)
        #expect(nonceTags.first?.values.count == 2)
        #expect(nonceTags.first?.values.last == String(difficulty))

        let signed = try signer.sign(mined)
        #expect(ProofOfWork.difficulty(of: signed.id) >= difficulty)
        try signed.verify()
        #expect(ProofOfWork.validate(event: signed, minimumDifficulty: difficulty))
    }

    @Test("mining replaces any pre-existing nonce tag")
    func mineReplacesExistingNonce() async throws {
        let signer = try testSigner()
        let seeded = try unsignedNote(for: signer, tags: [.nonce("0", target: 4), .hashtag("nostr")])

        let mined = try await ProofOfWork.mine(event: seeded, difficulty: 8)

        let nonceTags = mined.tags.filter { $0.name == .nonce }
        #expect(nonceTags.count == 1)
        #expect(nonceTags.first?.values.last == "8")
        // Non-nonce tags are preserved.
        #expect(mined.tags.contains(.hashtag("nostr")))
    }

    @Test("mining rejects a difficulty outside 0...256")
    func mineRejectsOutOfRangeDifficulty() async throws {
        let signer = try testSigner()
        await #expect(throws: ProofOfWork.Error.invalidDifficulty(257)) {
            _ = try await ProofOfWork.mine(event: try unsignedNote(for: signer), difficulty: 257)
        }
    }

    @Test("mining is cancellable")
    func mineIsCancellable() async throws {
        let signer = try testSigner()
        let note = try unsignedNote(for: signer)

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

    @Test("sign(_:proofOfWork:) mines a template under the signer's key and signs it")
    func signWithProofOfWork() async throws {
        let signer = try testSigner()
        var template = EventTemplate.textNote("proof of work", tags: [.nonce("0", target: 4), .hashtag("nostr")])
        template.createdAt = Timestamp(rawValue: 1_700_000_000)

        let signed = try await signer.sign(template, proofOfWork: 8)

        #expect(signed.publicKey == signer.publicKey)
        #expect(signed.kind == .textNote)
        #expect(signed.content == "proof of work")
        #expect(signed.createdAt == template.createdAt)
        #expect(signed.tags(named: .nonce).count == 1)
        #expect(signed.tags.contains(.hashtag("nostr")))
        #expect(ProofOfWork.difficulty(of: signed.id) >= 8)
        try signed.verify()
        #expect(ProofOfWork.validate(event: signed, minimumDifficulty: 8))
    }

    @Test("sign(_:proofOfWork:) works with a signer that is not an EventSigner")
    func signWithProofOfWorkThroughRemoteSigner() async throws {
        let keyPair = KeyPair()
        let signer = StubRemoteSigner(keyPair: keyPair)

        let signed = try await signer.sign(.textNote("mined remotely"), proofOfWork: 8)

        #expect(signed.publicKey == keyPair.publicKey)
        try signed.verify()
        #expect(ProofOfWork.validate(event: signed, minimumDifficulty: 8))
    }

    @Test("sign(_:proofOfWork:) rejects a difficulty outside 0...256")
    func signWithProofOfWorkRejectsDifficultyOutOfRange() async throws {
        let signer = try testSigner()
        await #expect(throws: ProofOfWork.Error.invalidDifficulty(257)) {
            _ = try await signer.sign(.textNote("too hard"), proofOfWork: 257)
        }
    }

    // MARK: - Validation Edges

    @Test("a zero or negative minimum difficulty accepts any event")
    func validateAcceptsZeroMinimum() throws {
        let signer = try testSigner()
        let note = signer.sign(.textNote("no work"))
        #expect(ProofOfWork.validate(event: note, minimumDifficulty: 0))
    }

    @Test("a lucky id without a commitment is rejected")
    func validateRejectsMissingCommitment() throws {
        let specEvent = try specEvent
        // The id clears 21 bits, but there is no nonce tag to commit to it.
        let event = Event(
            id: specEvent.id,
            publicKey: specEvent.publicKey,
            createdAt: specEvent.createdAt,
            kind: 1,
            tags: [],
            content: specEvent.content,
            signature: specEvent.signature
        )
        #expect(!ProofOfWork.validate(event: event, minimumDifficulty: 20))
    }
}
