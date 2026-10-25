import Foundation
import NostrCore
import Testing

@Suite("Event Coding Tests")
struct EventCodingTests {
    private func signedNote() throws -> Event {
        try EventSigner(keyPair: try KeyPair()).signTextNote(content: "gm")
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
        #expect(object["pubkey"] as? String == event.pubkey.hex)
        #expect(Set(object.keys) == ["id", "pubkey", "created_at", "kind", "tags", "content", "sig"])

        let decoded = try decode(object)
        #expect(decoded == event)
        #expect(try decoded.verify())
    }

    @Test("an unsigned rumor encodes without a sig key and decodes back as unsigned")
    func rumorOmitsSig() throws {
        let rumor = try UnsignedEvent(pubkey: try KeyPair().publicKey, kind: .privateDirectMessage, content: "hi")
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
        let rumor = try UnsignedEvent(pubkey: try KeyPair().publicKey, kind: .textNote, content: "hi").asRumor()
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
        let unsigned = UnsignedEvent(pubkey: try KeyPair().publicKey, kind: .textNote, content: "gm")
        let rumor = try unsigned.asRumor()

        #expect(rumor.id == (try unsigned.computedID))
        #expect(rumor.pubkey == unsigned.pubkey)
    }
}
