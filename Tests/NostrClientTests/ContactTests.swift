import Foundation
import Testing

@testable import NostrClient

@Suite("Contact Tests (NIP-02)")
struct ContactTests {

    @Test("Create contact with all fields")
    func createContactWithAllFields() {
        let contact = Contact(
            pubkey: "abc123",
            relayUrl: "wss://relay.example.com",
            petname: "alice"
        )

        #expect(contact.pubkey == "abc123")
        #expect(contact.relayUrl == "wss://relay.example.com")
        #expect(contact.petname == "alice")
    }

    @Test("Create contact with only pubkey")
    func createContactWithOnlyPubkey() {
        let contact = Contact(pubkey: "abc123")

        #expect(contact.pubkey == "abc123")
        #expect(contact.relayUrl == nil)
        #expect(contact.petname == nil)
    }

    @Test("Contact to tag - all fields")
    func contactToTagAllFields() {
        let contact = Contact(
            pubkey: "abc123",
            relayUrl: "wss://relay.example.com",
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
        let contact = Contact(pubkey: "abc123", relayUrl: "wss://relay.example.com")
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
        #expect(contact?.relayUrl == "wss://relay.example.com")
        #expect(contact?.petname == "alice")
    }

    @Test("Contact from tag - pubkey only")
    func contactFromTagPubkeyOnly() {
        let tag = ["p", "abc123"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == "abc123")
        #expect(contact?.relayUrl == nil)
        #expect(contact?.petname == nil)
    }

    @Test("Contact from tag - with empty relay")
    func contactFromTagWithEmptyRelay() {
        let tag = ["p", "abc123", "", "alice"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == "abc123")
        #expect(contact?.relayUrl == nil)
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
        let contact = try Contact(npub: keyPair.npub, petname: "test")

        #expect(contact.pubkey == keyPair.publicKeyHex)
        #expect(contact.petname == "test")
    }
}

@Suite("Contact List Event Tests")
struct ContactListEventTests {

    @Test("Sign contact list event")
    func signContactListEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: "pubkey1", relayUrl: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: "pubkey2", relayUrl: "wss://relay2.com"),
            Contact(pubkey: "pubkey3"),
        ]

        let event = try signer.signContactList(contacts)

        #expect(event.kind == 3)
        #expect(event.content == "")
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", "pubkey1", "wss://relay1.com", "alice"])
        #expect(event.tags[1] == ["p", "pubkey2", "wss://relay2.com"])
        #expect(event.tags[2] == ["p", "pubkey3"])
        #expect(try event.verify())
    }

    @Test("Sign contact list from pubkeys")
    func signContactListFromPubkeys() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let pubkeys = ["pubkey1", "pubkey2", "pubkey3"]
        let event = try signer.signContactList(pubkeys: pubkeys)

        #expect(event.kind == 3)
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", "pubkey1"])
        #expect(event.tags[1] == ["p", "pubkey2"])
        #expect(event.tags[2] == ["p", "pubkey3"])
    }

    @Test("Extract contacts from event")
    func extractContactsFromEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: "pubkey1", relayUrl: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: "pubkey2"),
        ]

        let event = try signer.signContactList(contacts)

        let extractedContacts = event.contacts
        #expect(extractedContacts != nil)
        #expect(extractedContacts?.count == 2)
        #expect(extractedContacts?[0].pubkey == "pubkey1")
        #expect(extractedContacts?[0].relayUrl == "wss://relay1.com")
        #expect(extractedContacts?[0].petname == "alice")
        #expect(extractedContacts?[1].pubkey == "pubkey2")
        #expect(extractedContacts?[1].relayUrl == nil)
    }

    @Test("isContactList property")
    func isContactListProperty() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contactEvent = try signer.signContactList([Contact(pubkey: "test")])
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
        let filter = Filter.contactList(pubkey: "abc123")

        #expect(filter.authors == ["abc123"])
        #expect(filter.kinds == [3])
        #expect(filter.limit == 1)
    }

    @Test("Contact list filter for multiple pubkeys")
    func contactListFilterMultiplePubkeys() {
        let filter = Filter.contactList(pubkeys: ["abc123", "def456"])

        #expect(filter.authors == ["abc123", "def456"])
        #expect(filter.kinds == [3])
        #expect(filter.limit == nil)
    }
}
