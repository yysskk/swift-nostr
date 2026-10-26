import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// `nsec` is the one NIP-19 case holding a hex string that nothing validates on the way in — every
/// other case holds a typed key or id, or a payload built by a validating initializer. Encoding a
/// malformed one produced a well-formed bech32 string over an empty payload, which reads as a real
/// key everywhere it is shown, stored, or shared.
@Suite("NIP-19 Bare Entity Encoding Tests")
struct NIP19EntityEncodingTests {
    private let validHex = String(repeating: "ab", count: 32)

    @Test(
        "encoding an nsec that is not hex throws invalidHex",
        arguments: [
            "not-hex",
            "abc",  // odd length
            "zz" + String(repeating: "ab", count: 31),  // right length, not hex
        ]
    )
    func nonHexNsecPayloadThrows(hex: String) {
        #expect(throws: NIP19Entity.Error.invalidHex) { _ = try NIP19Entity.nsec(hex).encoded }
    }

    @Test(
        "encoding an nsec whose hex is not 32 bytes throws invalidLength",
        arguments: [
            ("", 0),
            (String(repeating: "ab", count: 31), 31),  // one byte short
            (String(repeating: "ab", count: 33), 33),  // one byte long
        ]
    )
    func wrongLengthNsecPayloadThrows(hex: String, byteCount: Int) {
        #expect(throws: NIP19Entity.Error.invalidLength(byteCount)) { _ = try NIP19Entity.nsec(hex).encoded }
    }

    @Test("a valid bare entity still encodes and round-trips")
    func validBarePayloadRoundTrips() throws {
        let entities = [
            NIP19Entity.npub(PublicKey(validHex)!), .nsec(validHex), .note(EventID(validHex)!),
        ]
        for entity in entities {
            let encoded = try entity.encoded
            #expect(try NIP19Entity.decode(encoded) == entity)
        }
    }

    @Test("the encoded prefix matches the entity kind")
    func prefixesAreCorrect() throws {
        #expect(try NIP19Entity.npub(PublicKey(validHex)!).encoded.hasPrefix("npub1"))
        #expect(try NIP19Entity.nsec(validHex).encoded.hasPrefix("nsec1"))
        #expect(try NIP19Entity.note(EventID(validHex)!).encoded.hasPrefix("note1"))
    }
}
