import Foundation
import NostrCore
import Testing

@Suite("Bech32 decodeToWords Tests")
struct Bech32DecodeToWordsTests {
    @Test("round-trips data through encode and decodeToWords")
    func roundTrip() throws {
        let data = Data([0x00, 0x01, 0x02, 0xff, 0xab])
        let encoded = Bech32.encode(hrp: "npub", data: data)

        let (hrp, words) = try Bech32.decodeToWords(encoded)
        #expect(hrp == "npub")
        #expect(Data(Bech32.wordsToBytes(words)) == data)
    }

    @Test("throws instead of trapping on a non-ASCII human-readable part")
    func nonASCIIHumanReadablePartThrows() {
        // A non-ASCII HRP must not reach `hrpExpand`'s `asciiValue` force-unwrap.
        #expect(throws: NostrError.self) {
            try Bech32.decodeToWords("é1qpzry9x8gf2tvdw0s3jn54khce6mua7lmqqqxw")
        }
    }

    @Test("throws on a string with no separator")
    func missingSeparatorThrows() {
        #expect(throws: NostrError.self) {
            try Bech32.decodeToWords("notbech32")
        }
    }
}
