import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// The bare NIP-19 cases hold a hex string that nothing validates on the way in — unlike
/// `nprofile`, `nevent`, and `naddr`, which are built through validating initializers. Encoding a
/// malformed one produced a well-formed bech32 string over an empty payload, which reads as a real
/// key or event id everywhere it is shown, stored, or shared.
@Suite("NIP-19 Bare Entity Encoding Tests")
struct NIP19EntityEncodingTests {
    private let validHex = String(repeating: "ab", count: 32)

    @Test(
        "encoding a bare entity whose payload is not 32 bytes of hex throws",
        arguments: [
            "not-hex",
            "",
            "abc",  // odd length
            "zz" + String(repeating: "ab", count: 31),  // right length, not hex
            String(repeating: "ab", count: 31),  // one byte short
            String(repeating: "ab", count: 33),  // one byte long
        ]
    )
    func invalidBarePayloadThrows(hex: String) {
        #expect(throws: NostrError.invalidNIP19Entity) { _ = try NIP19Entity.npub(hex).encoded }
        #expect(throws: NostrError.invalidNIP19Entity) { _ = try NIP19Entity.nsec(hex).encoded }
        #expect(throws: NostrError.invalidNIP19Entity) { _ = try NIP19Entity.note(hex).encoded }
    }

    @Test("a valid bare entity still encodes and round-trips")
    func validBarePayloadRoundTrips() throws {
        for entity in [NIP19Entity.npub(validHex), .nsec(validHex), .note(validHex)] {
            let encoded = try entity.encoded
            #expect(try NIP19Entity.decode(encoded) == entity)
        }
    }

    @Test("the encoded prefix matches the entity kind")
    func prefixesAreCorrect() throws {
        #expect(try NIP19Entity.npub(validHex).encoded.hasPrefix("npub1"))
        #expect(try NIP19Entity.nsec(validHex).encoded.hasPrefix("nsec1"))
        #expect(try NIP19Entity.note(validHex).encoded.hasPrefix("note1"))
    }
}
