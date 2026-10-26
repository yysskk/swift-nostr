import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Contact Tests (NIP-02)")
struct ContactTests {
    private let alice = PublicKey.fixture("alice")

    @Test("Create contact with all fields")
    func createContactWithAllFields() {
        let contact = Contact(
            pubkey: alice,
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        #expect(contact.pubkey == alice)
        #expect(contact.relayURL == "wss://relay.example.com")
        #expect(contact.petname == "alice")
    }

    @Test("Create contact with only pubkey")
    func createContactWithOnlyPubkey() {
        let contact = Contact(pubkey: alice)

        #expect(contact.pubkey == alice)
        #expect(contact.relayURL == nil)
        #expect(contact.petname == nil)
    }

    @Test("Contact to tag - all fields")
    func contactToTagAllFields() {
        let contact = Contact(
            pubkey: alice,
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let tag = contact.toTag()
        #expect(tag == ["p", alice.hex, "wss://relay.example.com", "alice"])
    }

    @Test("Contact to tag - pubkey only")
    func contactToTagPubkeyOnly() {
        let contact = Contact(pubkey: alice)
        let tag = contact.toTag()
        #expect(tag == ["p", alice.hex])
    }

    @Test("Contact to tag - with relay only")
    func contactToTagWithRelayOnly() {
        let contact = Contact(pubkey: alice, relayURL: "wss://relay.example.com")
        let tag = contact.toTag()
        #expect(tag == ["p", alice.hex, "wss://relay.example.com"])
    }

    @Test("Contact to tag - with petname only")
    func contactToTagWithPetnameOnly() {
        let contact = Contact(pubkey: alice, petname: "alice")
        let tag = contact.toTag()
        #expect(tag == ["p", alice.hex, "", "alice"])
    }

    @Test("Contact from tag - all fields")
    func contactFromTagAllFields() {
        let tag = ["p", alice.hex, "wss://relay.example.com", "alice"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == "wss://relay.example.com")
        #expect(contact?.petname == "alice")
    }

    @Test("Contact from tag - pubkey only")
    func contactFromTagPubkeyOnly() {
        let tag = ["p", alice.hex]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == nil)
    }

    @Test("Contact from tag - with empty relay")
    func contactFromTagWithEmptyRelay() {
        let tag = ["p", alice.hex, "", "alice"]
        let contact = Contact.fromTag(tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == "alice")
    }

    @Test("Contact from tag - invalid tag type")
    func contactFromTagInvalidType() {
        let tag = ["e", alice.hex]
        let contact = Contact.fromTag(tag)
        #expect(contact == nil)
    }

    @Test("Contact from tag - too short")
    func contactFromTagTooShort() {
        let tag = ["p"]
        let contact = Contact.fromTag(tag)
        #expect(contact == nil)
    }

    @Test(
        "Contact from tag - rejects a pubkey that is not canonical hex",
        arguments: ["abc123", String(repeating: "A", count: 64), "", String(repeating: "a", count: 66)])
    func contactFromTagRejectsMalformedPubkey(pubkey: String) {
        #expect(Contact.fromTag(["p", pubkey, "wss://relay.example.com", "alice"]) == nil)
    }

    @Test("Contact encodes the relay URL under the relayURL key")
    func contactEncodesRelayURLKey() throws {
        let contact = Contact(
            pubkey: alice,
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(contact))
        let object = try #require(json as? [String: String])

        #expect(
            object == [
                "pubkey": alice.hex,
                "relayURL": "wss://relay.example.com",
                "petname": "alice",
            ])
    }

    @Test("Contact round-trips through Codable")
    func contactRoundTripsThroughCodable() throws {
        let contact = Contact(
            pubkey: alice,
            relayURL: "wss://relay.example.com",
            petname: "alice"
        )

        let decoded = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(contact))

        #expect(decoded == contact)
    }

    @Test("Contact decoding rejects a pubkey that is not canonical hex")
    func contactDecodingRejectsMalformedPubkey() {
        let json = Data(#"{"pubkey":"\#(alice.hex.uppercased())"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Contact.self, from: json)
        }
    }
}

@Suite("Contact List Event Tests")
struct ContactListEventTests {
    private let pubkey1 = PublicKey.fixture("pubkey1")
    private let pubkey2 = PublicKey.fixture("pubkey2")
    private let pubkey3 = PublicKey.fixture("pubkey3")

    @Test("Sign contact list event")
    func signContactListEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: pubkey1, relayURL: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: pubkey2, relayURL: "wss://relay2.com"),
            Contact(pubkey: pubkey3),
        ]

        let event = try signer.signContactList(contacts)

        #expect(event.kind == 3)
        #expect(event.content == "")
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", pubkey1.hex, "wss://relay1.com", "alice"])
        #expect(event.tags[1] == ["p", pubkey2.hex, "wss://relay2.com"])
        #expect(event.tags[2] == ["p", pubkey3.hex])
        #expect(try event.verify())
    }

    @Test("Sign contact list from pubkeys")
    func signContactListFromPubkeys() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let pubkeys = [pubkey1, pubkey2, pubkey3]
        let event = try signer.signContactList(pubkeys: pubkeys)

        #expect(event.kind == 3)
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", pubkey1.hex])
        #expect(event.tags[1] == ["p", pubkey2.hex])
        #expect(event.tags[2] == ["p", pubkey3.hex])
    }

    @Test("Extract contacts from event")
    func extractContactsFromEvent() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(pubkey: pubkey1, relayURL: "wss://relay1.com", petname: "alice"),
            Contact(pubkey: pubkey2),
        ]

        let event = try signer.signContactList(contacts)

        let extractedContacts = event.contacts
        #expect(extractedContacts != nil)
        #expect(extractedContacts?.count == 2)
        #expect(extractedContacts?[0].pubkey == pubkey1)
        #expect(extractedContacts?[0].relayURL == "wss://relay1.com")
        #expect(extractedContacts?[0].petname == "alice")
        #expect(extractedContacts?[1].pubkey == pubkey2)
        #expect(extractedContacts?[1].relayURL == nil)
    }

    @Test("Extract contacts skips p tags whose pubkey is not canonical hex")
    func extractContactsSkipsMalformedPubkeys() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.sign(
            UnsignedEvent(
                pubkey: signer.publicKey,
                kind: .contacts,
                rawTags: [
                    ["p", pubkey1.hex],
                    ["p", "pubkey2"],
                    ["p", pubkey3.hex.uppercased()],
                    ["p", pubkey3.hex, "", "carol"],
                ],
                content: ""
            ))

        #expect(event.contacts == [Contact(pubkey: pubkey1), Contact(pubkey: pubkey3, petname: "carol")])
    }

    @Test("isContactList property")
    func isContactListProperty() throws {
        let keyPair = try KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contactEvent = try signer.signContactList([Contact(pubkey: pubkey1)])
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
