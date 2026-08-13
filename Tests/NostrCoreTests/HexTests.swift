import Foundation
import NostrCore
import Testing

/// `Data(hexString:)` guards the boundary between untrusted strings and the byte buffers the
/// cryptography works on, so it has to reject everything that is not a plain hex digit pair.
/// Swift's `FixedWidthInteger.init?(_:radix:)` accepts a leading sign character, which would
/// otherwise let one identity be spelled several ways.
@Suite("Hex Decoding Tests")
struct HexTests {
    @Test("decodes lowercase, uppercase, and mixed-case hex")
    func decodesValidHex() {
        #expect(Data(hexString: "00ff") == Data([0x00, 0xff]))
        #expect(Data(hexString: "00FF") == Data([0x00, 0xff]))
        #expect(Data(hexString: "AbCd") == Data([0xab, 0xcd]))
        #expect(Data(hexString: "") == Data())
    }

    @Test("round-trips through hexEncodedString")
    func roundTrip() {
        let data = Data([0x00, 0x01, 0x7f, 0x80, 0xff])
        #expect(Data(hexString: data.hexEncodedString()) == data)
    }

    /// `UInt8("+1", radix: 16)` returns 1, so without an explicit digit check these strings would
    /// decode to the same bytes as their canonical spellings — two distinct strings mapping to one
    /// cryptographic identity.
    @Test(
        "rejects sign characters that the integer parser would otherwise accept",
        arguments: ["+1", "-1", "+f+f", "-0", "1+", "+123456"]
    )
    func rejectsSignCharacters(hex: String) {
        #expect(Data(hexString: hex) == nil)
    }

    @Test(
        "rejects non-hex characters and odd lengths",
        arguments: ["zz", "0g", " a", "a ", "0x1f", "abc", "a", "00 ff", "ff\n"]
    )
    func rejectsMalformedInput(hex: String) {
        #expect(Data(hexString: hex) == nil)
    }

    @Test("rejects whitespace and separators inside an otherwise valid string")
    func rejectsEmbeddedSeparators() {
        #expect(Data(hexString: "00:ff") == nil)
        #expect(Data(hexString: "00-ff") == nil)
    }
}
