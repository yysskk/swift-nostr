import Foundation
import NostrCore
import Testing

@Suite("PrivateKey Tests")
struct PrivateKeyTests {
    /// BIP-340 test vector 0: secret key 3 and its x-only public key.
    /// https://github.com/bitcoin/bips/blob/master/bip-0340/test-vectors.csv
    let hex = "0000000000000000000000000000000000000000000000000000000000000003"
    let publicKeyHex = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"
    let curveOrder = "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141"

    @Test("hex and data round-trip")
    func hexAndDataRoundTrip() throws {
        let privateKey = try PrivateKey(hex: hex)

        #expect(privateKey.hex == hex)
        #expect(privateKey.data.hexEncodedString() == hex)
        #expect(try PrivateKey(data: privateKey.data) == privateKey)
    }

    @Test("uppercase hex is accepted and normalized to lowercase")
    func uppercaseHexIsAccepted() throws {
        // BIP-340 test vector 1, spelled in uppercase as the vector file does.
        let uppercase = "B7E151628AED2A6ABF7158809CF4F3C762E7160F38B4DA56A784D9045190CFEF"
        let expectedPublicKeyHex = "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659"

        let privateKey = try PrivateKey(hex: uppercase)

        #expect(privateKey.hex == uppercase.lowercased())
        #expect(KeyPair(privateKey: privateKey).publicKey.hex == expectedPublicKeyHex)
    }

    @Test("nsec round-trips")
    func nsecRoundTrips() throws {
        let privateKey = try PrivateKey(hex: hex)

        #expect(privateKey.nsec.hasPrefix("nsec1"))
        #expect(try PrivateKey(nsec: privateKey.nsec) == privateKey)
    }

    @Test(
        "data of the wrong length is rejected with its byte count",
        arguments: [0, 16, 31, 33]
    )
    func wrongLengthDataIsRejected(count: Int) {
        #expect(throws: KeyPair.Error.invalidLength(count)) {
            try PrivateKey(data: Data(repeating: 1, count: count))
        }
    }

    @Test(
        "hex that is not 64 hexadecimal digits is rejected",
        arguments: [
            "", "abcd", "not-a-hex-string", String(repeating: "zz", count: 32), String(repeating: "ab", count: 33),
        ]
    )
    func malformedHexIsRejected(hex: String) {
        #expect(throws: KeyPair.Error.invalidHex) {
            try PrivateKey(hex: hex)
        }
    }

    @Test("zero and values not below the curve order are rejected")
    func outOfRangeScalarsAreRejected() {
        let aboveOrder = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        for hex in [String(repeating: "0", count: 64), curveOrder, aboveOrder] {
            #expect(throws: KeyPair.Error.invalidPrivateKey) {
                try PrivateKey(hex: hex)
            }
        }
    }

    @Test("a malformed nsec is rejected with the reason")
    func malformedNsecIsRejected() throws {
        let nsec = try PrivateKey(hex: hex).nsec
        let corrupted = String(nsec.dropLast()) + (nsec.hasSuffix("q") ? "p" : "q")
        let short = try Bech32.encode(hrp: "nsec", data: Data(repeating: 1, count: 31))
        let npub = try PublicKey(hex: publicKeyHex).npub

        #expect(throws: KeyPair.Error.invalidBech32(.invalidChecksum)) {
            try PrivateKey(nsec: corrupted)
        }
        #expect(throws: KeyPair.Error.unexpectedPrefix("npub")) {
            try PrivateKey(nsec: npub)
        }
        #expect(throws: KeyPair.Error.invalidLength(31)) {
            try PrivateKey(nsec: short)
        }
    }

    @Test("equal bytes are equal keys and hash alike")
    func equalityAndHashing() throws {
        let privateKey = try PrivateKey(hex: hex)
        let same = try PrivateKey(data: privateKey.data)
        let other = KeyPair().privateKey

        #expect(privateKey == same)
        #expect(privateKey != other)
        #expect(Set([privateKey, same, other]).count == 2)
    }

    @Test("printing, interpolation, and dump never reveal the key")
    func textualFormsAreRedacted() throws {
        let privateKey = KeyPair().privateKey
        var dumped = ""
        dump(privateKey, to: &dumped)
        var dumpedKeyPair = ""
        dump(KeyPair(privateKey: privateKey), to: &dumpedKeyPair)

        let forms = [
            privateKey.description,
            privateKey.debugDescription,
            "\(privateKey)",
            String(describing: privateKey),
            String(reflecting: privateKey),
            dumped,
            dumpedKeyPair,
        ]
        for form in forms {
            #expect(!form.contains(privateKey.hex))
            #expect(!form.contains(privateKey.nsec))
        }
        #expect(privateKey.description == "PrivateKey(<redacted>)")
        #expect(dumped.contains("PrivateKey(<redacted>)"))
    }

    @Test("a keypair derives the BIP-340 public key for the vector secret")
    func keyPairDerivesExpectedPublicKey() throws {
        let keyPair = KeyPair(privateKey: try PrivateKey(hex: hex))

        #expect(keyPair.publicKey.hex == publicKeyHex)
        #expect(keyPair.privateKey.hex == hex)
    }
}
