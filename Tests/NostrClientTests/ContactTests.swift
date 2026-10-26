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
            relayURL: RelayURL("wss://relay.example.com")!,
            petname: "alice"
        )

        #expect(contact.pubkey == alice)
        #expect(contact.relayURL == RelayURL("wss://relay.example.com"))
        #expect(contact.petname == "alice")
    }

    @Test("Create contact with only pubkey")
    func createContactWithOnlyPubkey() {
        let contact = Contact(pubkey: alice)

        #expect(contact.pubkey == alice)
        #expect(contact.relayURL == nil)
        #expect(contact.petname == nil)
    }

    @Test("Contact tag - all fields")
    func contactTagAllFields() {
        let contact = Contact(
            pubkey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
            petname: "alice"
        )

        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "wss://relay.example.com", "alice"])
    }

    @Test("Contact tag - pubkey only")
    func contactTagPubkeyOnly() {
        let contact = Contact(pubkey: alice)
        let tag = contact.tag
        #expect(tag == ["p", alice.hex])
    }

    @Test("Contact tag - with relay only")
    func contactTagWithRelayOnly() {
        let contact = Contact(pubkey: alice, relayURL: RelayURL("wss://relay.example.com")!)
        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "wss://relay.example.com"])
    }

    @Test("Contact tag - with petname only")
    func contactTagWithPetnameOnly() {
        let contact = Contact(pubkey: alice, petname: "alice")
        let tag = contact.tag
        #expect(tag == ["p", alice.hex, "", "alice"])
    }

    @Test("Contact init(tag:) - all fields")
    func contactInitTagAllFields() {
        let tag: Event.Tag = ["p", alice.hex, "wss://relay.example.com", "alice"]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == RelayURL("wss://relay.example.com"))
        #expect(contact?.petname == "alice")
    }

    @Test("Contact init(tag:) - pubkey only")
    func contactInitTagPubkeyOnly() {
        let tag: Event.Tag = ["p", alice.hex]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == nil)
    }

    @Test("Contact init(tag:) - with empty relay")
    func contactInitTagWithEmptyRelay() {
        let tag: Event.Tag = ["p", alice.hex, "", "alice"]
        let contact = Contact(tag: tag)

        #expect(contact != nil)
        #expect(contact?.pubkey == alice)
        #expect(contact?.relayURL == nil)
        #expect(contact?.petname == "alice")
    }

    @Test(
        "Contact init(tag:) - reads a malformed relay hint as absent",
        arguments: ["not a relay", "https://relay.example.com", "wss://relay.example.com/#frag"])
    func contactInitTagWithMalformedRelay(relay: String) {
        let contact = Contact(tag: ["p", alice.hex, relay, "alice"])

        #expect(contact?.pubkey == alice)
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
        "Contact init(tag:) - rejects a pubkey that is not canonical hex",
        arguments: ["abc123", String(repeating: "A", count: 64), "", String(repeating: "a", count: 66)])
    func contactInitTagRejectsMalformedPubkey(pubkey: String) {
        #expect(Contact(tag: ["p", pubkey, "wss://relay.example.com", "alice"]) == nil)
    }

    @Test("Contact round-trips through tag and init(tag:)")
    func contactTagRoundTrip() throws {
        let relay = try #require(RelayURL("wss://relay.example.com"))
        let contacts = [
            Contact(pubkey: alice),
            Contact(pubkey: alice, relayURL: relay),
            Contact(pubkey: alice, petname: "alice"),
            Contact(pubkey: alice, relayURL: relay, petname: "alice"),
        ]
        for contact in contacts {
            #expect(Contact(tag: contact.tag) == contact)
        }
    }

    @Test("Contact encodes the relay URL under the relayURL key")
    func contactEncodesRelayURLKey() throws {
        let contact = Contact(
            pubkey: alice,
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
            pubkey: alice,
            relayURL: RelayURL("wss://relay.example.com")!,
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
            Contact(pubkey: pubkey1, relayURL: RelayURL("wss://relay1.com")!, petname: "alice"),
            Contact(pubkey: pubkey2, relayURL: RelayURL("wss://relay2.com")!),
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
            Contact(pubkey: pubkey1, relayURL: RelayURL("wss://relay1.com")!, petname: "alice"),
            Contact(pubkey: pubkey2),
        ]

        let event = try signer.signContactList(contacts)

        let extractedContacts = event.contacts
        #expect(extractedContacts != nil)
        #expect(extractedContacts?.count == 2)
        #expect(extractedContacts?[0].pubkey == pubkey1)
        #expect(extractedContacts?[0].relayURL == RelayURL("wss://relay1.com"))
        #expect(extractedContacts?[0].petname == "alice")
        #expect(extractedContacts?[1].pubkey == pubkey2)
        #expect(extractedContacts?[1].relayURL == nil)
    }

    @Test("Extract contacts skips p tags whose pubkey is not canonical hex")
    func extractContactsSkipsMalformedPubkeys() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey,
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
        let filter = Filter.contactList(publicKey: .fixture("abc123"))

        #expect(filter.authors == [.fixture("abc123")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == 1)
    }

    @Test("Contact list filter for multiple pubkeys")
    func contactListFilterMultiplePubkeys() {
        let filter = Filter.contactList(publicKeys: [.fixture("abc123"), .fixture("def456")])

        #expect(filter.authors == [.fixture("abc123"), .fixture("def456")])
        #expect(filter.kinds == [3])
        #expect(filter.limit == nil)
    }
}
