import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-51 Set Tests")
struct NIP51SetTests {

    // MARK: - Kinds

    @Test("Set kinds have their NIP-51 raw values and are addressable")
    func setKinds() {
        let kinds: [(Event.Kind, Int)] = [
            (.followSet, 30000),
            (.relaySet, 30002),
            (.bookmarkSet, 30003),
            (.curationSet, 30004),
            (.videoCurationSet, 30005),
            (.pictureCurationSet, 30006),
            (.kindMuteSet, 30007),
            (.interestSet, 30015),
            (.emojiSet, 30030),
        ]
        for (kind, rawValue) in kinds {
            #expect(kind.rawValue == rawValue)
            #expect(kind.isAddressable)
        }
    }

    @Test("followSet shares its raw value with categorizedPeopleList")
    func followSetSharesRawValue() {
        #expect(Event.Kind.followSet == Event.Kind.categorizedPeopleList)
    }

    // MARK: - init validation

    @Test("init throws for a non-addressable kind")
    func initRejectsNonAddressableKind() {
        #expect(throws: (any Error).self) {
            try NostrListSet(kind: .textNote, identifier: "d")
        }
    }

    @Test("init throws for an empty identifier")
    func initRejectsEmptyIdentifier() {
        #expect(throws: (any Error).self) {
            try NostrListSet(kind: .bookmarkSet, identifier: "")
        }
    }

    // MARK: - signSet / openSet round-trip

    @Test("signSet then openSet restores metadata and items")
    func signOpenRoundTrip() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let publicItems: [Event.Tag] = [.event("public-note-id"), .hashtag("nostr")]
        let privateItems: [Event.Tag] = [.event("private-note-id"), .word("secret-word")]
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            imageURL: "https://example.com/cover.png",
            description: "Things to read later",
            publicItems: publicItems,
            privateItems: privateItems
        )

        let event = try signer.signSet(set)
        #expect(event.kind == .bookmarkSet)
        #expect(try event.verify())

        let opened = try signer.openSet(event)
        #expect(opened.kind == .bookmarkSet)
        #expect(opened.identifier == "reading")
        #expect(opened.title == "Reading list")
        #expect(opened.imageURL == "https://example.com/cover.png")
        #expect(opened.description == "Things to read later")
        #expect(opened.publicItems == publicItems)
        #expect(opened.privateItems == privateItems)
    }

    // MARK: - Tag ordering and content

    @Test("Signed event starts with a d tag and includes metadata only when set")
    func tagOrdering() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            publicItems: [.hashtag("nostr")]
        )

        let event = try signer.signSet(set)
        #expect(event.structuredTags.first?.name == "d")
        #expect(event.structuredTags.first?.primaryValue == "reading")
        #expect(event.tags(named: "title").first?.primaryValue == "Reading list")
        // image / description were not set, so no such tags appear.
        #expect(event.tags(named: "image").isEmpty)
        #expect(event.tags(named: "description").isEmpty)
    }

    @Test("Empty private items leave content empty")
    func emptyPrivateItems() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading", publicItems: [.hashtag("nostr")])

        let event = try signer.signSet(set)
        #expect(event.content == "")
    }

    @Test("Non-empty private items produce a base64 payload without the plaintext")
    func encryptedContentHidesPlaintext() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            privateItems: [Event.Tag(name: "private-tag", values: ["confidential-secret-value"])]
        )

        let event = try signer.signSet(set)
        #expect(!event.content.isEmpty)
        #expect(Data(base64Encoded: event.content) != nil)
        #expect(!event.content.contains("private-tag"))
        #expect(!event.content.contains("confidential-secret-value"))
    }

    @Test("A different signer cannot open the set")
    func differentSignerCannotOpen() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let other = EventSigner(keyPair: try KeyPair())
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading", privateItems: [.word("secret-word")])

        let event = try author.signSet(set)
        #expect(throws: (any Error).self) {
            try other.openSet(event)
        }
    }

    // MARK: - init(event:)

    @Test("init(event:) throws when there is no d tag")
    func eventInitRequiresIdentifier() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.sign(
            UnsignedEvent(pubkey: signer.publicKey, kind: .bookmarkSet, tags: [.hashtag("nostr")], content: "")
        )
        #expect(throws: (any Error).self) {
            try NostrListSet(event: event)
        }
    }

    @Test("init(event:) separates metadata from public items")
    func eventInitSeparatesMetadata() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let topic = Event.Tag(name: "t", values: ["topic"])
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            publicItems: [topic]
        )

        let event = try signer.signSet(set)
        let parsed = try NostrListSet(event: event)
        #expect(parsed.identifier == "reading")
        #expect(parsed.title == "Reading list")
        // The d and title tags are metadata, not public items.
        #expect(!parsed.publicItems.contains { $0.name == "d" })
        #expect(!parsed.publicItems.contains { $0.name == "title" })
        // The arbitrary topic tag is a public item.
        #expect(parsed.publicItems.contains(topic))
        // The public-only view leaves private items empty.
        #expect(parsed.privateItems.isEmpty)
    }

    // MARK: - Coordinate and naddr

    @Test("coordinate is kind:pubkey:identifier")
    func coordinate() throws {
        let author = String(repeating: "a", count: 64)
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading")
        #expect(set.coordinate(author: author) == "30003:\(author):reading")
    }

    @Test("naddr round-trips and matches NAddr(event:)")
    func naddrRoundTrip() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading")
        let event = try signer.signSet(set)

        let naddr = try set.naddr(author: signer.publicKey)
        #expect(naddr.identifier == "reading")
        #expect(naddr.author == signer.publicKey)
        #expect(naddr.kind == 30003)

        // Round-trips through its bech32 encoding.
        let decoded = try NAddr(bech32String: naddr.encoded)
        #expect(decoded == naddr)

        // Matches the coordinate derived directly from the signed event.
        let fromEvent = try NAddr(event: event)
        #expect(fromEvent.identifier == naddr.identifier)
        #expect(fromEvent.author == naddr.author)
        #expect(fromEvent.kind == naddr.kind)
    }

    // MARK: - Lossless read-modify-write

    @Test("An unmodeled public tag survives init(event:) and signSet")
    func losslessPublicItems() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let unusual = Event.Tag(name: "client", values: ["x"])
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            publicItems: [.hashtag("nostr"), unusual]
        )

        let event = try signer.signSet(set)
        let reread = try NostrListSet(event: event)
        #expect(reread.publicItems.contains(unusual))

        let resigned = try signer.signSet(reread)
        #expect(try NostrListSet(event: resigned).publicItems == set.publicItems)
    }
}
