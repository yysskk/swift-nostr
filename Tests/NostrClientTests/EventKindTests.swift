import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Event Kind Tests")
struct EventKindTests {

    @Test("integer literals and constants are interchangeable")
    func integerLiteralsAndConstants() {
        let kind: Event.Kind = 1
        #expect(kind == .textNote)
        #expect(kind.rawValue == 1)
        #expect(Event.Kind(rawValue: 1) == .textNote)
    }

    @Test("arbitrary kinds can be represented")
    func arbitraryKinds() {
        let liveEvent = Event.Kind(rawValue: 30311)
        #expect(liveEvent.rawValue == 30311)
        #expect(liveEvent != .longFormContent)
        #expect(liveEvent.description == "30311")
    }

    @Test("kinds compare by raw value")
    func comparable() {
        #expect(Event.Kind.setMetadata < .textNote)
        #expect(Event.Kind(rawValue: 30311) > .relayListMetadata)
    }

    @Test("NIP-01 range helpers")
    func rangeHelpers() {
        #expect(Event.Kind.setMetadata.isReplaceable)
        #expect(Event.Kind.contacts.isReplaceable)
        #expect(Event.Kind.relayListMetadata.isReplaceable)
        #expect(!Event.Kind.textNote.isReplaceable)

        #expect(Event.Kind.clientAuthentication.isEphemeral)
        #expect(!Event.Kind.textNote.isEphemeral)

        #expect(Event.Kind.longFormContent.isAddressable)
        #expect(Event.Kind(rawValue: 30311).isAddressable)
        #expect(!Event.Kind.relayListMetadata.isAddressable)

        // Range boundaries
        #expect(!Event.Kind(rawValue: 9999).isReplaceable)
        #expect(Event.Kind(rawValue: 10000).isReplaceable)
        #expect(Event.Kind(rawValue: 19999).isReplaceable)
        #expect(!Event.Kind(rawValue: 20000).isReplaceable)

        #expect(!Event.Kind(rawValue: 19999).isEphemeral)
        #expect(Event.Kind(rawValue: 20000).isEphemeral)
        #expect(Event.Kind(rawValue: 29999).isEphemeral)
        #expect(!Event.Kind(rawValue: 30000).isEphemeral)

        #expect(!Event.Kind(rawValue: 29999).isAddressable)
        #expect(Event.Kind(rawValue: 30000).isAddressable)
        #expect(Event.Kind(rawValue: 39999).isAddressable)
        #expect(!Event.Kind(rawValue: 40000).isAddressable)
    }

    @Test("Event encodes kind as a bare integer")
    func eventEncodesKindAsBareInt() throws {
        let event = Event(
            id: "id",
            pubkey: "pk",
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: [],
            content: "hi",
            sig: "sig"
        )
        let json = String(data: try JSONEncoder().encode(event), encoding: .utf8)!
        #expect(json.contains(#""kind":1"#))

        let decoded = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        #expect(decoded.kind == .textNote)
    }

    @Test("Event decodes unknown kinds")
    func eventDecodesUnknownKinds() throws {
        let json = """
            {"id":"id","pubkey":"pk","created_at":1700000000,"kind":31337,\
            "tags":[],"content":"","sig":"s"}
            """
        let event = try JSONDecoder().decode(Event.self, from: Data(json.utf8))
        #expect(event.kind == Event.Kind(rawValue: 31337))
    }

    @Test("Filter encodes kinds as bare integers")
    func filterEncodesKindsAsBareInts() throws {
        let filter = Filter(kinds: [.textNote, Event.Kind(rawValue: 30311)], limit: 10)
        let json = String(data: try JSONEncoder().encode(filter), encoding: .utf8)!
        #expect(json.contains(#""kinds":[1,30311]"#))

        let decoded = try JSONDecoder().decode(Filter.self, from: Data(json.utf8))
        #expect(decoded.kinds == [.textNote, Event.Kind(rawValue: 30311)])
    }

    @Test("signed events round-trip with struct kinds")
    func signedEventsRoundTrip() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let unsigned = UnsignedEvent(
            pubkey: signer.publicKey,
            kind: Event.Kind(rawValue: 31337),
            content: "custom kind"
        )
        let event = try signer.sign(unsigned)
        #expect(event.kind.rawValue == 31337)
        #expect(try event.verify())
    }
}
