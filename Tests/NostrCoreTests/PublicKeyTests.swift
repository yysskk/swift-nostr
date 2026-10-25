import Foundation
import NostrCore
import Testing

@Suite("PublicKey Tests")
struct PublicKeyTests {
    /// The NIP-19 specification's example key.
    /// https://github.com/nostr-protocol/nips/blob/master/19.md
    let hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

    @Test("the canonical hex form round-trips")
    func canonicalHexRoundTrips() throws {
        let publicKey = try PublicKey(hex: hex)

        #expect(publicKey.hex == hex)
        #expect(publicKey.data.count == 32)
        #expect(publicKey.data.hexEncodedString() == hex)
    }

    @Test("uppercase hex is rejected")
    func uppercaseHexIsRejected() {
        #expect(throws: NostrError.invalidPublicKey) {
            try PublicKey(hex: hex.uppercased())
        }
        #expect(throws: NostrError.invalidPublicKey) {
            try PublicKey(hex: "A" + hex.dropFirst())
        }
    }

    @Test(
        "hex of the wrong length is rejected",
        arguments: ["", "ab", String(repeating: "ab", count: 31), String(repeating: "ab", count: 33), "abc"]
    )
    func wrongLengthHexIsRejected(hex: String) {
        #expect(throws: NostrError.invalidPublicKey) {
            try PublicKey(hex: hex)
        }
    }

    @Test(
        "hex with non-hex characters is rejected",
        arguments: [
            String(repeating: "zz", count: 32),
            "+" + String(repeating: "0", count: 63),
            String(repeating: "０", count: 64),  // fullwidth zeros
            String(repeating: "0", count: 63) + " ",
        ]
    )
    func nonHexIsRejected(hex: String) {
        #expect(throws: NostrError.invalidPublicKey) {
            try PublicKey(hex: hex)
        }
    }

    @Test("bytes round-trip, and only 32 of them are accepted")
    func dataRoundTrips() throws {
        let data = Data((0..<32).map { UInt8($0) })
        let publicKey = try PublicKey(data: data)

        #expect(publicKey.data == data)
        #expect(publicKey.hex == data.hexEncodedString())
        for count in [0, 31, 33, 64] {
            #expect(throws: NostrError.invalidPublicKey) {
                try PublicKey(data: Data(repeating: 1, count: count))
            }
        }
    }

    @Test("npub encodes and decodes the NIP-19 example")
    func npubMatchesSpecVector() throws {
        #expect(try PublicKey(hex: hex).npub == npub)
        #expect(try PublicKey(npub: npub).hex == hex)
    }

    @Test("an all-uppercase npub decodes to the same key")
    func uppercaseNpubDecodes() throws {
        #expect(try PublicKey(npub: npub.uppercased()) == PublicKey(hex: hex))
    }

    @Test("a bech32 string with another prefix is not an npub")
    func wrongPrefixIsRejected() throws {
        let note = try EventID(hex: hex).note
        let nsec = try Bech32.encode(hrp: "nsec", data: try PublicKey(hex: hex).data)

        for string in [note, nsec] {
            #expect(throws: NostrError.invalidPublicKey) {
                try PublicKey(npub: string)
            }
        }
    }

    @Test("a malformed npub is rejected as an invalid public key")
    func malformedNpubIsRejected() throws {
        let corrupted = String(npub.dropLast()) + (npub.hasSuffix("q") ? "p" : "q")
        let short = try Bech32.encode(hrp: "npub", data: Data(repeating: 1, count: 31))

        for string in ["", "npub", corrupted, short] {
            #expect(throws: NostrError.invalidPublicKey) {
                try PublicKey(npub: string)
            }
        }
    }

    @Test("description is the hex form, and LosslessStringConvertible accepts only that")
    func losslessStringConversion() throws {
        let publicKey = try PublicKey(hex: hex)

        #expect(publicKey.description == hex)
        #expect("\(publicKey)" == hex)
        #expect(PublicKey(hex) == publicKey)
        #expect(PublicKey(hex.uppercased()) == nil)
        #expect(PublicKey(npub) == nil)
        #expect(PublicKey("") == nil)
    }

    @Test("encodes as a bare hex string and decodes back")
    func codableRoundTrip() throws {
        let publicKey = try PublicKey(hex: hex)
        let data = try JSONEncoder().encode(publicKey)

        #expect(String(decoding: data, as: UTF8.self) == "\"\(hex)\"")
        #expect(try JSONDecoder().decode(PublicKey.self, from: data) == publicKey)
    }

    @Test(
        "decoding a non-canonical string fails as corrupted data",
        arguments: [
            "3BF0C63FCB93463407AF97A5E5EE64FA883D107EF9E558472C4EB9AAAEFA459D",
            "3bf0c63f",
            "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6",
        ]
    )
    func decodingRejectsNonCanonical(string: String) throws {
        let data = try JSONEncoder().encode(string)

        #expect {
            try JSONDecoder().decode(PublicKey.self, from: data)
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }

    @Test("equal keys hash equally")
    func hashing() throws {
        let keys: Set<PublicKey> = [try PublicKey(hex: hex), try PublicKey(npub: npub), try KeyPair().publicKey]

        #expect(keys.count == 2)
    }
}
