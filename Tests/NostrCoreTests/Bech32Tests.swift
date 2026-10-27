import Foundation
import NostrCore
import Testing

@Suite("Bech32 Tests")
struct Bech32Tests {

    @Test("Encode and decode npub")
    func encodeDecodeNpub() throws {
        let publicKeyHex = "7e7e9c42a91bfef19fa929e5fda1b72e0ebc1a4c1141673e2794234d86addf4e"
        let publicKeyData = Data(hexString: publicKeyHex)!

        let encoded = try Bech32.encode(hrp: "npub", data: publicKeyData)
        #expect(encoded.hasPrefix("npub1"))

        let (hrp, decoded) = try Bech32.decode(encoded)
        #expect(hrp == "npub")
        #expect(decoded.hexEncodedString() == publicKeyHex)
    }

    @Test("Encode and decode nsec")
    func encodeDecodeNsec() throws {
        let privateKeyHex = "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35"
        let privateKeyData = Data(hexString: privateKeyHex)!

        let encoded = try Bech32.encode(hrp: "nsec", data: privateKeyData)
        #expect(encoded.hasPrefix("nsec1"))

        let (hrp, decoded) = try Bech32.decode(encoded)
        #expect(hrp == "nsec")
        #expect(decoded.hexEncodedString() == privateKeyHex)
    }

    @Test("Decode known npub")
    func decodeKnownNpub() throws {
        // Known test vector
        let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let expectedHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

        let (hrp, data) = try Bech32.decode(npub)
        #expect(hrp == "npub")
        #expect(data.hexEncodedString() == expectedHex)
    }

    @Test("Invalid bech32 throws error")
    func invalidBech32() {
        #expect(throws: Bech32.Error.missingSeparator) {
            _ = try Bech32.decode("invalid")
        }
    }

    @Test("Decoding reports why a string is not bech32")
    func decodingFailureReasons() {
        let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let cases: [(String, Bech32.Error)] = [
            ("1qpzry9x8", .invalidLength),
            ("npub1qpzry", .invalidLength),
            ("npub1qpzrybqq", .invalidCharacter("b")),
            ("nébu1qpzry9x8", .invalidHumanReadablePart),
            (String(npub.dropLast()) + "7", .invalidChecksum),
        ]
        for (string, expected) in cases {
            #expect(throws: expected) {
                _ = try Bech32.decode(string)
            }
        }
    }

    @Test("Case insensitive decoding")
    func caseInsensitiveDecoding() throws {
        let lowercase = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
        let uppercase = lowercase.uppercased()

        let (hrp1, data1) = try Bech32.decode(lowercase)
        let (hrp2, data2) = try Bech32.decode(uppercase)

        #expect(hrp1 == hrp2)
        #expect(data1 == data2)
    }

    @Test("Round trip encoding")
    func roundTripEncoding() throws {
        let keyPair = KeyPair()

        // Test nsec round trip
        let nsec = keyPair.privateKey.nsec
        let recreatedFromNsec = try KeyPair(nsec: nsec)
        #expect(recreatedFromNsec.privateKey.hex == keyPair.privateKey.hex)

        // Test npub round trip
        let npub = keyPair.publicKey.npub
        let publicKey = try PublicKey(npub: npub)
        #expect(publicKey.hex == keyPair.publicKey.hex)
    }
}
