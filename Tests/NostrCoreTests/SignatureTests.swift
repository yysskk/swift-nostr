import Foundation
import NostrCore
import Testing

@Suite("Signature Tests")
struct SignatureTests {
    let hex =
        "357ad83f176b67f0f8ce5ecc9999f716f301b31cb8a8679ed57d7ba70e46fb91"
        + "b92c6747f0cc9f355bac75556e6cba2530cf8af8c2735c4081adcda65c961a72"

    @Test("the canonical hex form round-trips")
    func canonicalHexRoundTrips() throws {
        let signature = try Signature(hex: hex)

        #expect(signature.hex == hex)
        #expect(signature.data.count == 64)
        #expect(signature.data.hexEncodedString() == hex)
    }

    @Test("uppercase hex is rejected")
    func uppercaseHexIsRejected() {
        #expect(throws: Signature.Error.invalidHex) {
            try Signature(hex: hex.uppercased())
        }
    }

    @Test(
        "hex of the wrong length is rejected",
        arguments: [
            "", String(repeating: "ab", count: 32), String(repeating: "ab", count: 63),
            String(repeating: "ab", count: 65),
        ]
    )
    func wrongLengthHexIsRejected(hex: String) {
        #expect(throws: Signature.Error.invalidHex) {
            try Signature(hex: hex)
        }
    }

    @Test("hex with non-hex characters is rejected")
    func nonHexIsRejected() {
        #expect(throws: Signature.Error.invalidHex) {
            try Signature(hex: String(repeating: "zz", count: 64))
        }
    }

    @Test("bytes round-trip, and only 64 of them are accepted")
    func dataRoundTrips() throws {
        let data = Data((0..<64).map { UInt8($0 * 3) })

        #expect(try Signature(data: data).data == data)
        for count in [0, 32, 63, 65] {
            #expect(throws: Signature.Error.invalidLength(count)) {
                try Signature(data: Data(repeating: 1, count: count))
            }
        }
    }

    @Test("description is the hex form, and LosslessStringConvertible accepts only that")
    func losslessStringConversion() throws {
        let signature = try Signature(hex: hex)

        #expect(signature.description == hex)
        #expect(Signature(hex) == signature)
        #expect(Signature(hex.uppercased()) == nil)
        #expect(Signature(String(hex.prefix(64))) == nil)
    }

    @Test("encodes as a bare hex string and decodes back")
    func codableRoundTrip() throws {
        let signature = try Signature(hex: hex)
        let data = try JSONEncoder().encode(signature)

        #expect(String(decoding: data, as: UTF8.self) == "\"\(hex)\"")
        #expect(try JSONDecoder().decode(Signature.self, from: data) == signature)
    }

    @Test("decoding a non-canonical string fails as corrupted data")
    func decodingRejectsNonCanonical() throws {
        #expect {
            try JSONDecoder().decode(Signature.self, from: try JSONEncoder().encode(String(hex.prefix(64))))
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }
}
