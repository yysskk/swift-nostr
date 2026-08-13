import Foundation
import NostrCore
import Testing

/// BIP-173 requires a decoder to reject strings that are not the canonical spelling of their
/// payload: mixed case, and trailing bits that either do not fit in the final byte or are not zero.
/// Without those checks a single key has many checksum-valid spellings, which is the same class of
/// identity malleability as accepting a leading `+` in a hex string.
@Suite("Bech32 Canonical Encoding Tests")
struct Bech32CanonicalTests {
    private let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

    // MARK: - Case

    @Test("all-lowercase and all-uppercase decode to the same payload")
    func uniformCaseIsAccepted() throws {
        let (lowerHRP, lowerData) = try Bech32.decode(npub)
        let (upperHRP, upperData) = try Bech32.decode(npub.uppercased())

        #expect(lowerHRP == upperHRP)
        #expect(lowerData == upperData)
    }

    /// BIP-173: "Decoders MUST NOT accept strings where some characters are uppercase and some are
    /// lowercase." The string was lowercased before any case check, so mixed case slipped through.
    @Test("mixed case is rejected by decode")
    func mixedCaseIsRejectedByDecode() {
        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.decode("NPUB180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6")
        }
        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.decode(
                "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6W6")
        }
    }

    /// `decodeToWords` is the entry point BOLT-11 uses, and it applies the same case rule. Uppercase
    /// invoices are common in QR codes, so the all-uppercase form must keep working.
    @Test("decodeToWords accepts uniform case and rejects mixed case")
    func decodeToWordsCaseHandling() throws {
        let (_, lowerWords) = try Bech32.decodeToWords(npub)
        let (_, upperWords) = try Bech32.decodeToWords(npub.uppercased())
        #expect(lowerWords == upperWords)

        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.decodeToWords(
                "NPUB180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6")
        }
    }

    // MARK: - Canonical padding

    /// A 32-byte payload occupies 52 five-bit words (260 bits), so the final word carries four
    /// padding bits that must be zero. Flipping them yields 15 further checksum-valid strings that
    /// all decode to the identical public key.
    @Test("non-zero trailing padding bits are rejected")
    func nonZeroPaddingIsRejected() throws {
        let (hrp, words) = try Bech32.decodeToWords(npub)
        #expect(words.count == 52)

        for padding in UInt8(1)...UInt8(15) {
            var mutated = words
            mutated[51] = (mutated[51] & ~0x0f) | padding
            let reencoded = TestBech32.encode(hrp: hrp, words: mutated)

            // The mutated string is checksum-valid: decodeToWords accepts it and returns the
            // mutated words, so only the canonical-padding check can reject it.
            let (_, roundTripped) = try Bech32.decodeToWords(reencoded)
            #expect(roundTripped == mutated)

            #expect(throws: NostrError.invalidBech32) {
                _ = try Bech32.decode(reencoded)
            }
        }
    }

    /// 51 words carry 255 bits — seven bits more than the 31 whole bytes they decode to. BIP-173
    /// rejects a leftover of five bits or more, because the payload could have been spelled in
    /// fewer words.
    @Test("a word count with too many leftover bits is rejected")
    func excessLeftoverBitsAreRejected() throws {
        let (hrp, words) = try Bech32.decodeToWords(npub)
        let truncated = Array(words.prefix(51))
        let reencoded = TestBech32.encode(hrp: hrp, words: truncated)

        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.decode(reencoded)
        }
    }

    @Test("the canonical spelling still decodes to the expected key")
    func canonicalStillDecodes() throws {
        let (hrp, data) = try Bech32.decode(npub)

        #expect(hrp == "npub")
        #expect(data.count == 32)
        #expect(try PublicKey(npub: npub).hex == data.hexEncodedString())
    }

    // MARK: - Encoding

    /// The checksum is computed over the HRP as given, while decoding recomputes it over the
    /// lowercased string, so a non-lowercase HRP produced output that could never be decoded back.
    @Test("encode rejects a human-readable part it could not decode back")
    func encodeRejectsUnusableHRP() {
        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.encode(hrp: "", data: Data([0x01]))
        }
        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.encode(hrp: "NPUB", data: Data([0x01]))
        }
        #expect(throws: NostrError.invalidBech32) {
            _ = try Bech32.encode(hrp: "np ub", data: Data([0x01]))
        }
    }

    @Test("encode and decode remain inverses for a valid prefix")
    func encodeDecodeRoundTrip() throws {
        let payload = Data((0..<32).map { UInt8($0) })
        let encoded = try Bech32.encode(hrp: "npub", data: payload)
        let (hrp, decoded) = try Bech32.decode(encoded)

        #expect(hrp == "npub")
        #expect(decoded == payload)
    }
}

/// A minimal bech32 encoder over raw five-bit words, used to build the non-canonical spellings the
/// tests above feed back in. `Bech32.encode` takes bytes and always emits canonical padding, so it
/// cannot express these cases.
private enum TestBech32 {
    private static let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    static func encode(hrp: String, words: [UInt8]) -> String {
        let checksum = createChecksum(hrp: hrp, values: words)
        return hrp + "1" + String((words + checksum).map { charset[Int($0)] })
    }

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generator: [UInt32] = [0x3b6a_57b2, 0x2650_8e6d, 0x1ea1_19fa, 0x3d42_33dd, 0x2a14_62b3]
        var chk: UInt32 = 1

        for value in values {
            let top = chk >> 25
            chk = (chk & 0x1ff_ffff) << 5 ^ UInt32(value)
            for i in 0..<5 where (top >> i) & 1 == 1 {
                chk ^= generator[i]
            }
        }

        return chk
    }

    private static func hrpExpand(_ hrp: String) -> [UInt8] {
        var result = [UInt8]()
        for char in hrp {
            result.append(UInt8(char.asciiValue! >> 5))
        }
        result.append(0)
        for char in hrp {
            result.append(UInt8(char.asciiValue! & 31))
        }
        return result
    }

    private static func createChecksum(hrp: String, values: [UInt8]) -> [UInt8] {
        let mod = polymod(hrpExpand(hrp) + values + [0, 0, 0, 0, 0, 0]) ^ 1
        return (0..<6).map { UInt8((mod >> (5 * (5 - $0))) & 31) }
    }
}
