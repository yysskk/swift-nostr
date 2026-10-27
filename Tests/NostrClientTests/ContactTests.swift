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
            publicKey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
            petname: "alice"
        )

        #expect(contact.publicKey == alice)
        #expect(contact.relayURL == RelayURL("wss://relay.example.com"))
        #expect(contact.petname == "alice")
    }

    @Test("Create contact with only public key")
    func createContactWithOnlyPublicKey() {
        let contact = Contact(publicKey: alice)

        #expect(contact.publicKey == alice)
        #expect(contact.relayURL == nil)
        #expect(contact.petname == nil)
    }

    @Test("Contact tag - all fields")
    func contactTagAllFields() {
        let contact = Contact(
            publicKey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
            petname: "alice"
        )

        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "wss://relay.example.com", "alice"])
    }

    @Test("Contact tag - public key only")
    func contactTagPublicKeyOnly() {
        let contact = Contact(publicKey: alice)
        let tag = contact.tag
        #expect(tag == ["p", alice.hex])
    }

    @Test("Contact tag - with relay only")
    func contactTagWithRelayOnly() {
        let contact = Contact(publicKey: alice, relayURL: RelayURL("wss://relay.example.com")!)
        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "wss://relay.example.com"])
    }

    @Test("Contact tag - with petname only")
    func contactTagWithPetnameOnly() {
        let contact = Contact(publicKey: alice, petname: "alice")
        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "", "alice"])
    }

    @Test("Contact init(tag:) - all fields")
    func contactInitTagAllFields() {
        let tag: Event.Tag = ["p", alice.hex, "wss://relay.example.com", "alice"]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.publicKey == alice)
        #expect(contact?.relayURL == RelayURL("wss://relay.example.com"))
        #expect(contact?.petname == "alice")
    }

    @Test("Contact init(tag:) - public key only")
    func contactInitTagPublicKeyOnly() {
        let tag: Event.Tag = ["p", alice.hex]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.publicKey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == nil)
    }

    @Test("Contact init(tag:) - with empty relay")
    func contactInitTagWithEmptyRelay() {
        let tag: Event.Tag = ["p", alice.hex, "", "alice"]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.publicKey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == "alice")
    }

    @Test(
        "Contact init(tag:) - reads a malformed relay hint as absent",
        arguments: ["not a relay", "https://relay.example.com", "wss://relay.example.com/#frag"])
    func contactInitTagWithMalformedRelay(relay: String) {
        let contact = Contact(tag: ["p", alice.hex, relay, "alice"])

        #expect(contact?.publicKey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == "alice")
    }

    @Test("Contact init(tag:) - writes the relay hint back in canonical form")
    func contactInitTagCanonicalizesRelay() {
        let contact = Contact(tag: ["p", alice.hex, "WSS://Relay.Example.com/"])

        #expect(contact?.relayURL == RelayURL("wss://relay.example.com"))
        #expect(contact?.tag == ["p", alice.hex, "wss://relay.example.com"])
    }

    @Test("Contact init(tag:) - invalid tag type")
    func contactInitTagInvalidType() {
        let tag: Event.Tag = ["e", alice.hex]
        let contact = Contact(tag: tag)
        #expect(contact == nil)
    }

    @Test("Contact init(tag:) - too short")
    func contactInitTagTooShort() {
        let tag: Event.Tag = ["p"]
        let contact = Contact(tag: tag)
        #expect(contact == nil)
    }

    @Test(
        "Contact init(tag:) - rejects a public key that is not canonical hex",
        arguments: ["abc123", String(repeating: "A", count: 64), "", String(repeating: "a", count: 66)])
    func contactInitTagRejectsMalformedPublicKey(publicKey: String) {
        #expect(Contact(tag: ["p", publicKey, "wss://relay.example.com", "alice"]) == nil)
    }

    @Test("Contact round-trips through tag and init(tag:)")
    func contactTagRoundTrip() throws {
        let relay = try #require(RelayURL("wss://relay.example.com"))
        let contacts = [
            Contact(publicKey: alice),
            Contact(publicKey: alice, relayURL: relay),
            Contact(publicKey: alice, petname: "alice"),
            Contact(publicKey: alice, relayURL: relay, petname: "alice"),
        ]
        for contact in contacts {
            #expect(Contact(tag: contact.tag) == contact)
        }
    }

    @Test("Contact encodes the relay URL under the relayURL key")
    func contactEncodesRelayURLKey() throws {
        let contact = Contact(
            publicKey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
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
            publicKey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
            petname: "alice"
        )

        let decoded = try JSONDecoder().decode(Contact.self, from: JSONEncoder().encode(contact))

        #expect(decoded == contact)
    }

    @Test("Contact decoding rejects a public key that is not canonical hex")
    func contactDecodingRejectsMalformedPublicKey() {
        let json = Data(#"{"pubkey":"\#(alice.hex.uppercased())"}"#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Contact.self, from: json)
        }
    }
}

@Suite("Contact List Event Tests")
struct ContactListEventTests {
    private let publicKey1 = PublicKey.fixture("publicKey1")
    private let publicKey2 = PublicKey.fixture("publicKey2")
    private let publicKey3 = PublicKey.fixture("publicKey3")

    @Test("Sign contact list event")
    func contactListEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(publicKey: publicKey1, relayURL: RelayURL("wss://relay1.com")!, petname: "alice"),
            Contact(publicKey: publicKey2, relayURL: RelayURL("wss://relay2.com")!),
            Contact(publicKey: publicKey3),
        ]

        let event = signer.sign(.contactList(contacts))

        #expect(event.kind == 3)
        #expect(event.content == "")
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", publicKey1.hex, "wss://relay1.com", "alice"])
        #expect(event.tags[1] == ["p", publicKey2.hex, "wss://relay2.com"])
        #expect(event.tags[2] == ["p", publicKey3.hex])
        #expect(try event.verify())
    }

    @Test("Contacts without a relay or petname become bare p tags")
    func contactListFromPublicKeys() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let publicKeys = [publicKey1, publicKey2, publicKey3]
        let event = signer.sign(.contactList(publicKeys.map { Contact(publicKey: $0) }))

        #expect(event.kind == 3)
        #expect(event.tags.count == 3)
        #expect(event.tags[0] == ["p", publicKey1.hex])
        #expect(event.tags[1] == ["p", publicKey2.hex])
        #expect(event.tags[2] == ["p", publicKey3.hex])
    }

    @Test("Extract contacts from event")
    func extractContactsFromEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contacts = [
            Contact(publicKey: publicKey1, relayURL: RelayURL("wss://relay1.com")!, petname: "alice"),
            Contact(publicKey: publicKey2),
        ]

        let event = signer.sign(.contactList(contacts))

        let extractedContacts = event.contacts
        #expect(extractedContacts != nil)
        #expect(extractedContacts?.count == 2)
        #expect(extractedContacts?[0].publicKey == publicKey1)
        #expect(extractedContacts?[0].relayURL == RelayURL("wss://relay1.com"))
        #expect(extractedContacts?[0].petname == "alice")
        #expect(extractedContacts?[1].publicKey == publicKey2)
        #expect(extractedContacts?[1].relayURL == nil)
    }

    @Test("Extract contacts skips p tags whose public key is not canonical hex")
    func extractContactsSkipsMalformedPublicKeys() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey,
                kind: .contacts,
                rawTags: [
                    ["p", publicKey1.hex],
                    ["p", "publicKey2"],
                    ["p", publicKey3.hex.uppercased()],
                    ["p", publicKey3.hex, "", "carol"],
                ],
                content: ""
            ))

        #expect(event.contacts == [Contact(publicKey: publicKey1), Contact(publicKey: publicKey3, petname: "carol")])
    }

    @Test("isContactList property")
    func isContactListProperty() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let contactEvent = signer.sign(.contactList([Contact(publicKey: publicKey1)]))
        let textNote = signer.sign(.textNote("Hello"))

        #expect(contactEvent.isContactList == true)
        #expect(textNote.isContactList == false)
    }

    @Test("contacts property returns nil for non-contact event")
    func contactsPropertyReturnsNilForNonContactEvent() throws {
        let keyPair = KeyPair()
        let signer = EventSigner(keyPair: keyPair)

        let textNote = signer.sign(.textNote("Hello"))
        #expect(textNote.contacts == nil)
    }
}

@Suite("Contact List Filter Tests")
struct ContactListFilterTests {

    @Test("Contact list filter for single public key")
    func contactListFilterSinglePublicKey() {
        let filter = Filter.contactList(publicKey: .fixture("abc123"))

        #expect(filter.authors == [.fixture("abc123")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == 1)
    }

    @Test("Contact list filter for multiple public keys")
    func contactListFilterMultiplePublicKeys() {
        let filter = Filter.contactList(publicKeys: [.fixture("abc123"), .fixture("def456")])

        #expect(filter.authors == [.fixture("abc123"), .fixture("def456")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == nil)
    }
}
