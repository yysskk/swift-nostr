import Foundation
import NostrCore
import Testing

@Suite("Bech32 encode Tests")
struct Bech32EncodeTests {
    @Test("encode throws instead of trapping on a non-ASCII human-readable part")
    func nonASCIIHumanReadablePartThrows() {
        // A non-ASCII HRP must not reach `hrpExpand`'s `asciiValue` force-unwrap.
        #expect(throws: Bech32.Error.invalidHumanReadablePart) {
            try Bech32.encode(hrp: "é", data: Data([0x00, 0x01]))
        }
    }
}
