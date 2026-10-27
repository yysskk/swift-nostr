import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("EventCoordinate Tests")
struct EventCoordinateTests {
    let publicKey = PublicKey.fixture("author")

    @Test("the kind:pubkey:identifier form round-trips")
    func roundTrip() throws {
        let string = "30023:\(publicKey.hex):my-article"
        let coordinate = try #require(EventCoordinate(string))

        #expect(coordinate.kind == .longFormContent)
        #expect(coordinate.publicKey == publicKey)
        #expect(coordinate.identifier == "my-article")
        #expect(coordinate.description == string)
        #expect(coordinate == EventCoordinate(kind: .longFormContent, publicKey: publicKey, identifier: "my-article"))
    }

    @Test("only the first two colons separate parts, so an identifier may contain colons")
    func identifierWithColons() throws {
        let string = "30023:\(publicKey.hex):a:b::c:"
        let coordinate = try #require(EventCoordinate(string))

        #expect(coordinate.identifier == "a:b::c:")
        #expect(coordinate.description == string)
    }

    @Test("an empty identifier, as for a replaceable event, round-trips")
    func emptyIdentifier() throws {
        let string = "10000:\(publicKey.hex):"
        let coordinate = try #require(EventCoordinate(string))

        #expect(coordinate.kind == .muteList)
        #expect(coordinate.identifier.isEmpty)
        #expect(coordinate.description == string)
    }

    @Test(
        "malformed strings are rejected",
        arguments: [
            "",
            "30023",
            "30023:\(PublicKey.fixture("author").hex)",
            ":\(PublicKey.fixture("author").hex):d",
            "kind:\(PublicKey.fixture("author").hex):d",
            "-1:\(PublicKey.fixture("author").hex):d",
            "+1:\(PublicKey.fixture("author").hex):d",
            "030023:\(PublicKey.fixture("author").hex):d",
            "30023::d",
            "30023:pubkey:d",
            "30023:\(PublicKey.fixture("author").hex.uppercased()):d",
            "30023:\(PublicKey.fixture("author").hex.dropLast()):d",
        ]
    )
    func rejectsMalformed(string: String) {
        #expect(EventCoordinate(string) == nil)
    }

    @Test("encodes to and decodes from JSON as its string")
    func codableAsString() throws {
        let coordinate = EventCoordinate(kind: .longFormContent, publicKey: publicKey, identifier: "a:b")
        let data = try JSONEncoder().encode(coordinate)

        #expect(try JSONDecoder().decode(String.self, from: data) == "30023:\(publicKey.hex):a:b")
        #expect(try JSONDecoder().decode(EventCoordinate.self, from: data) == coordinate)
    }

    @Test("decoding an invalid string fails with dataCorrupted")
    func decodingInvalidStringFails() throws {
        let data = try JSONEncoder().encode("30023:pubkey:d")

        #expect {
            try JSONDecoder().decode(EventCoordinate.self, from: data)
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }

    @Test("Event.coordinate reads the d tag of an addressable event and is empty for a replaceable one")
    func eventCoordinate() {
        let signer = EventSigner(keyPair: KeyPair())
        let article = signer.sign(EventTemplate(kind: .longFormContent, tags: [.identifier("post")]))
        let untagged = signer.sign(EventTemplate(kind: .longFormContent))
        let muteList = signer.sign(EventTemplate(kind: .muteList, tags: [.identifier("ignored")]))
        let note = signer.sign(EventTemplate(kind: .textNote))

        #expect(article.coordinate?.description == "30023:\(signer.publicKey.hex):post")
        #expect(untagged.coordinate?.description == "30023:\(signer.publicKey.hex):")
        #expect(muteList.coordinate?.description == "10000:\(signer.publicKey.hex):")
        #expect(note.coordinate == nil)
    }

    @Test("Tag.address writes the coordinate and an optional relay hint")
    func addressTag() throws {
        let coordinate = EventCoordinate(kind: .longFormContent, publicKey: publicKey, identifier: "a:b")

        #expect(Tag.address(coordinate).rawArray == ["a", "30023:\(publicKey.hex):a:b"])
        #expect(
            Tag.address(coordinate, relayURL: try RelayURL(string: "wss://r.example")).rawArray
                == ["a", "30023:\(publicKey.hex):a:b", "wss://r.example"])
    }
}
