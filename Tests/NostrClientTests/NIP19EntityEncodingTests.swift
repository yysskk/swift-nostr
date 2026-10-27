import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-19 Bare Entity Encoding Tests")
struct NIP19EntityEncodingTests {
    private let validHex = String(repeating: "ab", count: 32)

    // The NIP-19 specification's nsec example.
    private let nsecVector = "nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5"
    private let nsecVectorHex = "67dea2ed018072d675f5415ecfaed7d2597555e202d85b3d65ea4e58d2d92ffa"

    @Test("a valid bare entity still encodes and round-trips")
    func validBarePayloadRoundTrips() throws {
        let entities = [
            NIP19Entity.npub(PublicKey(validHex)!), .nsec(try PrivateKey(hex: validHex)),
            .note(EventID(validHex)!),
        ]
        for entity in entities {
            let encoded = try entity.encoded
            #expect(try NIP19Entity.decode(encoded) == entity)
        }
    }

    @Test("the encoded prefix matches the entity kind")
    func prefixesAreCorrect() throws {
        #expect(try NIP19Entity.npub(PublicKey(validHex)!).encoded.hasPrefix("npub1"))
        #expect(try NIP19Entity.nsec(PrivateKey(hex: validHex)).encoded.hasPrefix("nsec1"))
        #expect(try NIP19Entity.note(EventID(validHex)!).encoded.hasPrefix("note1"))
    }

    @Test("the NIP-19 nsec vector decodes to its private key and encodes back")
    func nsecVectorRoundTrips() throws {
        let entity = try NIP19Entity.decode(nsecVector)
        #expect(entity == .nsec(try PrivateKey(hex: nsecVectorHex)))
        #expect(try entity.encoded == nsecVector)
    }

    @Test(
        "an nsec whose payload is not a valid secp256k1 scalar throws invalidPrivateKey",
        arguments: [
            String(repeating: "00", count: 32),  // zero
            "fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141",  // the curve order
        ]
    )
    func invalidScalarNsecThrows(hex: String) throws {
        let encoded = try Bech32.encode(hrp: "nsec", data: Data(hexString: hex)!)
        #expect(throws: NIP19Entity.Error.invalidPrivateKey) { _ = try NIP19Entity.decode(encoded) }
    }

    @Test("an nsec entity's description and reflection do not show the key")
    func nsecDescriptionIsRedacted() throws {
        let entity = try NIP19Entity.decode(nsecVector)
        var dumped = ""
        dump(entity, to: &dumped)
        for output in [String(describing: entity), String(reflecting: entity), "\(entity)", dumped] {
            #expect(!output.contains(nsecVectorHex))
            #expect(!output.contains(nsecVector))
        }
    }
}
