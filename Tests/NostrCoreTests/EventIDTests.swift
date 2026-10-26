import Foundation
import NostrCore
import Testing

@Suite("EventID Tests")
struct EventIDTests {
    /// The note used by the NIP-19 tests elsewhere in the suite.
    let hex = "4cd665db042864ee600ee976d6cfcc7c5ce743859462f94a347cd970d88a5f3b"
    let note = "note1fntxtkcy9pjwucqwa9mddn7v03wwwsu9j330jj350nvhpky2tuaspk6nqc"

    @Test("the canonical hex form round-trips")
    func canonicalHexRoundTrips() throws {
        let id = try EventID(hex: hex)

        #expect(id.hex == hex)
        #expect(id.data.count == 32)
        #expect(id.data.hexEncodedString() == hex)
    }

    @Test("uppercase hex is rejected")
    func uppercaseHexIsRejected() {
        #expect(throws: EventID.Error.invalidHex) {
            try EventID(hex: hex.uppercased())
        }
    }

    @Test(
        "hex of the wrong length is rejected",
        arguments: ["", "ab", String(repeating: "ab", count: 31), String(repeating: "ab", count: 33)]
    )
    func wrongLengthHexIsRejected(hex: String) {
        #expect(throws: EventID.Error.invalidHex) {
            try EventID(hex: hex)
        }
    }

    @Test(
        "hex with non-hex characters is rejected",
        arguments: [String(repeating: "zz", count: 32), "-" + String(repeating: "0", count: 63)]
    )
    func nonHexIsRejected(hex: String) {
        #expect(throws: EventID.Error.invalidHex) {
            try EventID(hex: hex)
        }
    }

    @Test("bytes round-trip, and only 32 of them are accepted")
    func dataRoundTrips() throws {
        let data = Data((0..<32).map { UInt8(255 - $0) })

        #expect(try EventID(data: data).data == data)
        for count in [0, 31, 33] {
            #expect(throws: EventID.Error.invalidLength(count)) {
                try EventID(data: Data(repeating: 1, count: count))
            }
        }
    }

    @Test("note encodes and decodes the NIP-19 form")
    func noteRoundTrips() throws {
        #expect(try EventID(hex: hex).note == note)
        #expect(try EventID(note: note).hex == hex)
    }

    @Test("a bech32 string with another prefix, or a malformed one, is not a note")
    func invalidNoteIsRejected() throws {
        let npub = try PublicKey(hex: hex).npub
        let corrupted = String(note.dropLast()) + (note.hasSuffix("q") ? "p" : "q")

        let cases: [(String, EventID.Error)] = [
            (npub, .unexpectedPrefix("npub")),
            (corrupted, .invalidBech32(.invalidChecksum)),
            ("", .invalidBech32(.missingSeparator)),
            ("note1", .invalidBech32(.invalidLength)),
        ]
        for (string, expected) in cases {
            #expect(throws: expected) {
                try EventID(note: string)
            }
        }
        let short = try Bech32.encode(hrp: "note", data: Data(repeating: 1, count: 31))
        #expect(throws: EventID.Error.invalidLength(31)) {
            try EventID(note: short)
        }
    }

    @Test("description is the hex form, and LosslessStringConvertible accepts only that")
    func losslessStringConversion() throws {
        let id = try EventID(hex: hex)

        #expect(id.description == hex)
        #expect(EventID(hex) == id)
        #expect(EventID(hex.uppercased()) == nil)
        #expect(EventID(note) == nil)
    }

    @Test("ids order by their bytes")
    func ordering() throws {
        let low = try EventID(hex: "00" + String(repeating: "ff", count: 31))
        let high = try EventID(hex: "01" + String(repeating: "00", count: 31))

        #expect(low < high)
        #expect([high, low].sorted() == [low, high])
    }

    @Test("encodes as a bare hex string and decodes back")
    func codableRoundTrip() throws {
        let id = try EventID(hex: hex)
        let data = try JSONEncoder().encode(id)

        #expect(String(decoding: data, as: UTF8.self) == "\"\(hex)\"")
        #expect(try JSONDecoder().decode(EventID.self, from: data) == id)
    }

    @Test("decoding a non-canonical string or a non-string fails as corrupted or mistyped data")
    func decodingRejectsNonCanonical() throws {
        #expect {
            try JSONDecoder().decode(EventID.self, from: try JSONEncoder().encode(hex.uppercased()))
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(EventID.self, from: Data("42".utf8))
        }
    }
}
