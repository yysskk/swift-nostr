import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Contact Tests (NIP-02)")
struct ContactTests {

    @Test("Create contact with all fields")
    func createContactWithAllFields() {
        let contact = Contact(
            pubkey: "abc123",
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        #expect(contact.pubkey == "abc123")
        #expect(contact.relayURL == "wss://relay.example.com")
        #expect(contact.petname == "alice")
    }

    @Test("Create contact with only pubkey")
    func createContactWithOnlyPubkey() {
        let contact = Contact(pubkey: "abc123")

        #expect(contact.pubkey == "abc123")
        #expect(contact.relayURL == nil)
        #expect(contact.petname == nil)
    }

    @Test("Contact to tag - all fields")
    func contactToTagAllFields() {
        let contact = Contact(
            pubkey: "abc123",
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let tag = contact.toTag()
        #expect(tag == ["p", "abc123", "wss://relay.example.com", "alice"])
    }

    @Test("Contact to tag - pubkey only")
    func contactToTagPubkeyOnly() {
        let contact = Contact(pubkey: "abc123")
        let tag = contact.toTag()
        #expect(tag == ["p", "abc123"])
    }

    @Test("Contact to tag - with relay only")
    func contactToTagWithRelayOnly() {
        let contact = Contact(pubkey: "abc123", relayURL: "wss://relay.example.com")
        let tag = contact.toTag()
        #expect(tag == ["p", "abc123", "wss://relay.example.com"])
    }

    @Test("Contact to tag - with petname only")
    func contactToTagWithPetnameOnly() {
        let contact = Contact(pubkey: "abc123", petname: "alice")
        let tag = contact.toTag()
        #expect(tag == ["p", "abc123", "", "alice"])
    }

    @Test("Contact from tag - all fields")
    func contactFromTagAllFields() {
        let tag = ["p", "abc123", "wss://relay.example.com", "alice"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == "abc123")
        #expect(contact?.relayURL == "wss://relay.example.com")
        #expect(contact?.petname == "alice")
    }

    @Test("Contact from tag - pubkey only")
    func contactFromTagPubkeyOnly() {
        let tag = ["p", "abc123"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == "abc123")
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == nil)
    }

    @Test("Contact from tag - with empty relay")
    func contactFromTagWithEmptyRelay() {
        let tag = ["p", "abc123", "", "alice"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == "abc123")
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == "alice")
    }

    @Test("Contact from tag - invalid tag type")
    func contactFromTagInvalidType() {
        let tag = ["e", "abc123"]
        let contact = Contact.fromTag(tag)
        #expect(contact == nil)
    }

    @Test("Contact from tag - too short")
    func contactFromTagTooShort() {
        let tag = ["p"]
        let contact = Contact.fromTag(tag)
        #expect(contact == nil)
    }

    @Test("Create contact from npub")
    func createContactFromNpub() throws {
        let keyPair = try KeyPair()
        let contact = try Contact(npub: keyPair.publicKey.npub, petname: "test")

        #expect(contact.pubkey == keyPair.publicKey.hex)
        #expect(contact.petname == "test")
    }

    @Test("Contact encodes the relay URL under the relayURL key")
    func contactEncodesRelayURLKey() throws {
        let contact = Contact(
            pubkey: "abc123",
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contact))
        let object = try #require(json as? [String: String])

        #expect(
            object == [
                "pubkey": "abc123",
                "relayURL": "wss://relay.example.com",
                "petname": "alice",
            ])
    }

    @Test("Contact round-trips through Codable")
    func contactRoundTripsThroughCodable() throws {
        let contact = Contact(
            pubkey: "abc123",
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let decoded = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(contact))

        #expect(decoded == contact)
    }
}

@Suite("Contact List Event Tests")
struct ContactListEventTests {
    private let pubkey1Hex = PublicKey.fixture("pubkey1").hex
    private let pubkey2Hex = PublicKey.fixture("pubkey2").hex
    private let pubkey3Hex = PublicKey.fixture("pubkey3").hex

    @Test("Sign contact list event")
    func signContactListEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: pubkey1Hex, relayURL: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: pubkey2Hex, relayURL: "wss://relay2.com"),
            Contact(pubkey: pubkey3Hex),
        ]

        let event = try signer.signContactList(contacts)

        #expect(event.kind == 3)
        #expect(event.content == "")
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", pubkey1Hex, "wss://relay1.com", "alice"])
        #expect(event.tags[1] == ["p", pubkey2Hex, "wss://relay2.com"])
        #expect(event.tags[2] == ["p", pubkey3Hex])
        #expect(try event.verify())
    }

    @Test("Sign contact list rejects a contact whose pubkey is not hex")
    func signContactListRejectsMalformedPubkey() throws {
        let signer = EventSigner(keyPair: try KeyPair())

        #expect(throws: NostrError.invalidPublicKey) {
            try signer.signContactList([Contact(pubkey: pubkey1Hex), Contact(pubkey: "pubkey2")])
        }
    }

    @Test("Sign contact list from pubkeys")
    func signContactListFromPubkeys() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let pubkeys = [pubkey1Hex, pubkey2Hex, pubkey3Hex]
        let event = try signer.signContactList(pubkeys: pubkeys)

        #expect(event.kind == 3)
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", pubkey1Hex])
        #expect(event.tags[1] == ["p", pubkey2Hex])
        #expect(event.tags[2] == ["p", pubkey3Hex])
    }

    @Test("Extract contacts from event")
    func extractContactsFromEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: pubkey1Hex, relayURL: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: pubkey2Hex),
        ]

        let event = try signer.signContactList(contacts)

        let extractedContacts = event.contacts
        #expect(extractedContacts != nil)
        #expect(extractedContacts?.count == 2)
        #expect(extractedContacts?[0].pubkey == pubkey1Hex)
        #expect(extractedContacts?[0].relayURL == "wss://relay1.com")
        #expect(extractedContacts?[0].petname == "alice")
        #expect(extractedContacts?[1].pubkey == pubkey2Hex)
        #expect(extractedContacts?[1].relayURL == nil)
    }

    @Test("isContactList property")
    func isContactListProperty() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contactEvent = try signer.signContactList([Contact(pubkey: pubkey1Hex)])
        let textNote = try signer.signTextNote(content: "Hello")

        #expect(contactEvent.isContactList == true)
        #expect(textNote.isContactList == false)
    }

    @Test("contacts property returns nil for non-contact event")
    func contactsPropertyReturnsNilForNonContactEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = try signer.signTextNote(content: "Hello")
        #expect(textNote.contacts == nil)
    }
}

@Suite("Contact List Filter Tests")
struct ContactListFilterTests {

    @Test("Contact list filter for single pubkey")
    func contactListFilterSinglePubkey() {
        let filter = Filter.contactList(pubkey: .fixture("abc123"))

        #expect(filter.authors == [.fixture("abc123")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == 1)
    }

    @Test("Contact list filter for multiple pubkeys")
    func contactListFilterMultiplePubkeys() {
        let filter = Filter.contactList(pubkeys: [.fixture("abc123"), .fixture("def456")])

        #expect(filter.authors == [.fixture("abc123"), .fixture("def456")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == nil)
    }
}
