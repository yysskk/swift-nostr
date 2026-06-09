import Foundation
import Testing

@testable import NostrClient

@Suite("Event Tests")
struct EventTests {

    @Test("Create unsigned event")
    func createUnsignedEvent() throws {
        let keyPair = try KeyPair()
        let unsigned = UnsignedEvent(
            pubkey: keyPair.publicKeyHex,
            kind: .textNote,
            content: "Hello, Nostr!"
        )

        #expect(unsigned.pubkey == keyPair.publicKeyHex)
        #expect(unsigned.kind == 1)
        #expect(unsigned.content == "Hello, Nostr!")
        #expect(unsigned.tags.isEmpty)
    }

    @Test("Serialize unsigned event for hashing")
    func serializeForHashing() throws {
        let pubkey = "a".padding(toLength: 64, withPad: "0", startingAt: 0)
        let unsigned = UnsignedEvent(
            pubkey: pubkey,
            createdAt: 1_234_567_890,
            kind: 1,
            tags: [["p", "test"]],
            content: "test content"
        )

        let serialized = try unsigned.serializedForHashing()
        let json = String(data: serialized, encoding: .utf8)!

        #expect(json.contains("\"p\""))
        #expect(json.contains("test content"))
        #expect(json.contains("1234567890"))
    }

    @Test("Sign and verify event")
    func signAndVerifyEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let unsigned = UnsignedEvent(
            pubkey: keyPair.publicKeyHex,
            kind: .textNote,
            content: "Test message"
        )

        let signed = try signer.sign(unsigned)

        #expect(signed.id.count == 64)
        #expect(signed.sig.count == 128)
        #expect(signed.pubkey == keyPair.publicKeyHex)
        #expect(signed.content == "Test message")

        // Verify the signature
        let isValid = try signed.verify()
        #expect(isValid)
    }

    @Test("Sign text note convenience method")
    func signTextNote() throws {
        let signer = try EventSigner(privateKeyHex: "e8f32e723decf4051aefac8e2c93c9c5b214313817cdb01a1494b917c8436b35")

        let event = try signer.signTextNote(content: "Hello!")

        #expect(event.kind == 1)
        #expect(event.content == "Hello!")
        #expect(try event.verify())
    }

    @Test("Sign metadata event")
    func signMetadata() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let metadata = UserMetadata(
            name: "TestUser",
            about: "A test user",
            picture: "https://example.com/avatar.png"
        )

        let event = try signer.signMetadata(metadata)

        #expect(event.kind == 0)
        #expect(event.content.contains("TestUser"))
        #expect(try event.verify())
    }

    @Test("Sign reaction event")
    func signReaction() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        // Create a target event to react to
        let targetEvent = try signer.signTextNote(content: "Original post")

        let reaction = try signer.signReaction(to: targetEvent, content: "🤙")

        #expect(reaction.kind == 7)
        #expect(reaction.content == "🤙")
        #expect(reaction.tags.contains { $0.first == "e" && $0.contains(targetEvent.id) })
        #expect(reaction.tags.contains { $0.first == "p" && $0.contains(targetEvent.pubkey) })
        #expect(try reaction.verify())
    }

    @Test("Event kind constants")
    func eventKindConstants() {
        #expect(Event.Kind.setMetadata.rawValue == 0)
        #expect(Event.Kind.textNote.rawValue == 1)
        #expect(Event.Kind.recommendRelay.rawValue == 2)
        #expect(Event.Kind.contacts.rawValue == 3)
        #expect(Event.Kind.encryptedDirectMessage.rawValue == 4)
        #expect(Event.Kind.eventDeletion.rawValue == 5)
        #expect(Event.Kind.repost.rawValue == 6)
        #expect(Event.Kind.reaction.rawValue == 7)
    }

    @Test("Event JSON encoding/decoding")
    func eventJsonCoding() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)
        let event = try signer.signTextNote(content: "JSON test")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Event.self, from: data)

        #expect(decoded.id == event.id)
        #expect(decoded.pubkey == event.pubkey)
        #expect(decoded.content == event.content)
        #expect(decoded.sig == event.sig)
    }
}
