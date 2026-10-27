import Foundation
import NostrCore
import NostrTestSupport
import Testing

@Suite("Event Coding Tests")
struct EventCodingTests {
    private func signedNote() throws -> Event {
        EventSigner(keyPair: KeyPair()).sign(.textNote("gm"))
    }

    private func jsonObject(_ event: Event) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
    }

    private func decode(_ object: [String: Any]) throws -> Event {
        try JSONDecoder().decode(Event.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("a signed event encodes its signature under the NIP-01 sig key and round-trips")
    func signedEventRoundTrips() throws {
        let event = try signedNote()
        let object = try jsonObject(event)

        #expect(object["sig"] as? String == event.signature?.hex)
        #expect(object["signature"] == nil)
        #expect(object["id"] as? String == event.id.hex)
        #expect(object["pubkey"] as? String == event.publicKey.hex)
        #expect(Set(object.keys) == ["id", "pubkey", "created_at", "kind", "tags", "content", "sig"])

        let decoded = try decode(object)
        #expect(decoded == event)
        try decoded.verify()
    }

    @Test("a NIP-01 event decodes its pubkey field into publicKey")
    func nip01WireKeyDecodesIntoPublicKey() throws {
        let publicKeyHex = String(repeating: "cd", count: 32)
        let json = #"""
            {"id":"\#(String(repeating: "ab", count: 32))","pubkey":"\#(publicKeyHex)","created_at":1234567890,\#
            "kind":1,"tags":[],"content":"Hello","sig":"\#(String(repeating: "ef", count: 64))"}
            """#

        let event = try JSONDecoder().decode(Event.self, from: Data(json.utf8))

        #expect(event.publicKey == (try PublicKey(hex: publicKeyHex)))
        #expect(try jsonObject(event)["pubkey"] as? String == publicKeyHex)
    }

    @Test("an unsigned rumor encodes without a sig key and decodes back as unsigned")
    func rumorOmitsSig() throws {
        let rumor = UnsignedEvent(publicKey: KeyPair().publicKey, kind: .privateDirectMessage, content: "hi")
            .asRumor()
        let object = try jsonObject(rumor)

        #expect(rumor.signature == nil)
        #expect(object["sig"] == nil)
        #expect(Set(object.keys) == ["id", "pubkey", "created_at", "kind", "tags", "content"])

        let decoded = try decode(object)
        #expect(decoded == rumor)
        #expect(decoded.signature == nil)
    }

    @Test("an empty sig decodes as an unsigned rumor")
    func emptySigDecodesAsRumor() throws {
        let rumor = UnsignedEvent(publicKey: KeyPair().publicKey, kind: .textNote, content: "hi").asRumor()
        var object = try jsonObject(rumor)
        object["sig"] = ""

        let decoded = try decode(object)
        #expect(decoded.signature == nil)
        #expect(decoded.id == rumor.id)
        #expect(try jsonObject(decoded)["sig"] == nil)
    }

    @Test(
        "a malformed id, pubkey, or sig fails decoding",
        arguments: [
            ("id", "abc123"),
            ("id", String(repeating: "AB", count: 32)),
            ("pubkey", "pk"),
            ("pubkey", String(repeating: "ab", count: 33)),
            ("sig", "sig"),
            ("sig", String(repeating: "AB", count: 64)),
            ("sig", String(repeating: "ab", count: 32)),
        ]
    )
    func malformedFieldFailsDecoding(field: String, value: String) throws {
        var object = try jsonObject(try signedNote())
        object[field] = value

        #expect {
            try decode(object)
        } throws: { error in
            guard case DecodingError.dataCorrupted = error else { return false }
            return true
        }
    }

    @Test("a missing id or pubkey fails decoding", arguments: ["id", "pubkey"])
    func missingFieldFailsDecoding(field: String) throws {
        var object = try jsonObject(try signedNote())
        object[field] = nil

        #expect(throws: DecodingError.self) {
            try decode(object)
        }
    }

    @Test("a signed event's id is the id its unsigned form computes")
    func idMatchesComputedID() throws {
        let unsigned = UnsignedEvent(publicKey: KeyPair().publicKey, kind: .textNote, content: "gm")
        let rumor = unsigned.asRumor()

        #expect(rumor.id == unsigned.computedID)
        #expect(rumor.publicKey == unsigned.publicKey)
    }

    /// The tag shapes a relay may send beyond what the typed constructors write: an unknown name,
    /// extra values, empty-string placeholders, a bare name, an empty name, and an empty array.
    private let unusualRawTags = [
        ["e", EventID.fixture("note").hex, "", "reply"], ["x-custom", "a", "b", "c"], ["t"], [""], [],
        ["p", PublicKey.fixture("alice").hex, "", ""],
    ]

    /// A signed event carrying ``unusualRawTags``, written out as a relay would send it, keys sorted.
    private func receivedEventJSON() throws -> String {
        let signer = EventSigner(keyPair: KeyPair())
        let event = try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey, createdAt: Timestamp(rawValue: 1_700_000_000), kind: .textNote,
                tags: unusualRawTags.map(Event.Tag.init(rawArray:)), content: "odd tags"))
        let signature = try #require(event.signature)
        return #"{"content":"odd tags","created_at":1700000000,"id":"\#(event.id.hex)","kind":1,"#
            + #""pubkey":"\#(event.publicKey.hex)","sig":"\#(signature.hex)","tags":[["e","#
            + #""\#(EventID.fixture("note").hex)","","reply"],["x-custom","a","b","c"],["t"],[""],[],"#
            + #"["p","\#(PublicKey.fixture("alice").hex)","",""]]}"#
    }

    /// Each tag must survive decoding and re-encoding unchanged, or the id no longer matches.
    @Test("an event with unusual tags round-trips through JSON byte for byte")
    func unusualTagsRoundTripByteForByte() throws {
        let json = try receivedEventJSON()
        let event = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        #expect(event.tags.map(\.rawArray) == unusualRawTags)

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        #expect(String(decoding: try encoder.encode(event), as: UTF8.self) == json)
    }

    @Test("a received event with unusual tags verifies")
    func receivedEventWithUnusualTagsVerifies() throws {
        let event = try JSONDecoder().decode(Event.self, from: Data(try receivedEventJSON().utf8))
        try event.verify()
    }
}
