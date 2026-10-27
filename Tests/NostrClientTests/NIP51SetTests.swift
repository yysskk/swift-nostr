import Foundation
import NostrCore
import NostrTestSupport
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

    // MARK: - init validation

    @Test("init throws invalidKind for a non-addressable kind")
    func initRejectsNonAddressableKind() {
        #expect(throws: NostrListSet.Error.invalidKind(.textNote)) {
            try NostrListSet(kind: .textNote, identifier: "d")
        }
    }

    @Test("init throws missingIdentifier for an empty identifier")
    func initRejectsEmptyIdentifier() {
        #expect(throws: NostrListSet.Error.missingIdentifier) {
            try NostrListSet(kind: .bookmarkSet, identifier: "")
        }
    }

    // MARK: - set(_:encryptingWith:) / init(event:decryptingWith:) round-trip

    /// Builds `set`'s template, encrypting with `signer`, and signs it with the same signer.
    private func sign(_ set: NostrListSet, with signer: some NostrSigning) async throws -> Event {
        try await signer.sign(EventTemplate.set(set, encryptingWith: signer))
    }

    @Test(
        "A set round-trips its metadata and items through a local and a remote signer",
        arguments: [false, true]
    )
    func signOpenRoundTrip(remote: Bool) async throws {
        let keyPair = KeyPair()
        let signer: any NostrSigning = remote ? StubRemoteSigner(keyPair: keyPair) : EventSigner(keyPair: keyPair)
        let publicItems: [Event.Tag] = [.event(EventID.fixture("public-note-id")), .hashtag("nostr")]
        let privateItems: [Event.Tag] = [.event(EventID.fixture("private-note-id")), .word("secret-word")]
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            imageURL: "https://example.com/cover.png",
            description: "Things to read later",
            publicItems: publicItems,
            privateItems: privateItems
        )

        let event = try await sign(set, with: signer)
        #expect(event.kind == .bookmarkSet)
        #expect(event.publicKey == keyPair.publicKey)
        try event.verify()

        let opened = try await NostrListSet(event: event, decryptingWith: signer)
        #expect(opened.kind == .bookmarkSet)
        #expect(opened.identifier == "reading")
        #expect(opened.title == "Reading list")
        #expect(opened.imageURL == "https://example.com/cover.png")
        #expect(opened.description == "Things to read later")
        #expect(opened.publicItems == publicItems)
        #expect(opened.privateItems == privateItems)
    }

    // MARK: - Tag ordering and content

    @Test("set(_:encryptingWith:) orders d, title, image, description, then public items")
    func templateLayout() async throws {
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            imageURL: "https://example.com/cover.png",
            description: "Things to read later",
            publicItems: [.hashtag("nostr"), .reference(URL(string: "https://example.com")!)]
        )

        let template = try await EventTemplate.set(set, encryptingWith: FailingSigner())

        #expect(template.kind == .bookmarkSet)
        #expect(
            template.tags.map(\.rawArray) == [
                ["d", "reading"],
                ["title", "Reading list"],
                ["image", "https://example.com/cover.png"],
                ["description", "Things to read later"],
                ["t", "nostr"],
                ["r", "https://example.com"],
            ])
        #expect(template.content == "")
    }

    @Test("Signed event starts with a d tag and includes metadata only when set")
    func tagOrdering() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            publicItems: [.hashtag("nostr")]
        )

        let event = try await sign(set, with: signer)
        #expect(event.tags.first?.name == "d")
        #expect(event.tags.first?.primaryValue == "reading")
        #expect(event.tags(named: "title").first?.primaryValue == "Reading list")
        // image / description were not set, so no such tags appear.
        #expect(event.tags(named: "image").isEmpty)
        #expect(event.tags(named: "description").isEmpty)
    }

    @Test("Empty private items leave content empty without asking the signer to encrypt")
    func emptyPrivateItems() async throws {
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading", publicItems: [.hashtag("nostr")])

        let template = try await EventTemplate.set(set, encryptingWith: FailingSigner())
        #expect(template.content == "")

        // Reading empty content back needs no decryption either.
        let event = EventSigner(keyPair: KeyPair()).sign(template)
        let opened = try await NostrListSet(event: event, decryptingWith: FailingSigner())
        #expect(opened.privateItems.isEmpty)
        #expect(opened.publicItems == [.hashtag("nostr")])
    }

    @Test("Non-empty private items produce a base64 payload without the plaintext")
    func encryptedContentHidesPlaintext() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            privateItems: [Event.Tag(name: "private-tag", values: ["confidential-secret-value"])]
        )

        let event = try await sign(set, with: signer)
        #expect(!event.content.isEmpty)
        #expect(Data(base64Encoded: event.content) != nil)
        #expect(!event.content.contains("private-tag"))
        #expect(!event.content.contains("confidential-secret-value"))
    }

    // MARK: - init(event:decryptingWith:) errors

    @Test("A different signer cannot decrypt the set")
    func differentSignerCannotOpen() async throws {
        let author = EventSigner(keyPair: KeyPair())
        let other = EventSigner(keyPair: KeyPair())
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading", privateItems: [.word("secret-word")])

        let event = try await sign(set, with: author)
        await #expect(throws: (any Error).self) {
            try await NostrListSet(event: event, decryptingWith: other)
        }
    }

    @Test("init(event:decryptingWith:) throws missingIdentifier when there is no d tag, before decrypting")
    func decryptingInitRequiresIdentifier() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let content = try signer.nip44Encrypt(#"[["t","secret"]]"#, to: signer.publicKey)
        let event = signer.sign(
            EventTemplate(kind: .bookmarkSet, tags: [.hashtag("nostr")], content: content))

        await #expect(throws: NostrListSet.Error.missingIdentifier) {
            try await NostrListSet(event: event, decryptingWith: FailingSigner())
        }
    }

    @Test("Content that decrypts to something other than a tag array throws malformedPrivateItems")
    func nonTagArrayContentThrows() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let content = try signer.nip44Encrypt(#"{"not":"a tag array"}"#, to: signer.publicKey)
        let event = signer.sign(
            EventTemplate(kind: .bookmarkSet, tags: [.identifier("reading")], content: content))

        await #expect(throws: NostrListSet.Error.malformedPrivateItems) {
            try await NostrListSet(event: event, decryptingWith: signer)
        }
    }

    // MARK: - init(event:)

    @Test("init(event:) throws missingIdentifier when there is no d tag")
    func eventInitRequiresIdentifier() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey, kind: .bookmarkSet, tags: [.hashtag("nostr")], content: ""
            )
        )
        #expect(throws: NostrListSet.Error.missingIdentifier) {
            try NostrListSet(event: event)
        }
    }

    @Test("init(event:) separates metadata from public items")
    func eventInitSeparatesMetadata() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let topic = Event.Tag(name: "t", values: ["topic"])
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading list",
            publicItems: [topic]
        )

        let event = try await sign(set, with: signer)
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
        let author = PublicKey.fixture("author")
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading")
        #expect(set.coordinate(author: author).description == "30003:\(author.hex):reading")
    }

    @Test("naddr round-trips and matches NAddr(event:)")
    func naddrRoundTrip() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let set = try NostrListSet(kind: .bookmarkSet, identifier: "reading")
        let event = try await sign(set, with: signer)

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
        #expect(naddr.coordinate == set.coordinate(author: signer.publicKey))
        #expect(event.coordinate == naddr.coordinate)
    }

    // MARK: - Lossless read-modify-write

    @Test("An unmodeled public tag survives init(event:) and set(_:encryptingWith:)")
    func losslessPublicItems() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        let unusual = Event.Tag(name: "client", values: ["x"])
        let set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            publicItems: [.hashtag("nostr"), unusual]
        )

        let event = try await sign(set, with: signer)
        let reread = try NostrListSet(event: event)
        #expect(reread.publicItems.contains(unusual))

        let resigned = try await sign(reread, with: signer)
        #expect(try NostrListSet(event: resigned).publicItems == set.publicItems)
    }

    @Test("set(_:encryptingWith:) drops reserved metadata tags left in publicItems, avoiding duplicates")
    func setTemplateDeduplicatesReservedTags() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        // A caller stuffs reserved metadata tags into publicItems; the dedicated properties
        // must remain the single source of truth so the event has no duplicate reserved tags.
        var set = try NostrListSet(
            kind: .bookmarkSet,
            identifier: "reading",
            title: "Reading",
            imageURL: "https://x/cover.png",
            description: "My reading list"
        )
        set.publicItems = [
            Event.Tag(name: "d", values: ["injected"]),
            Event.Tag(name: "title", values: ["Injected"]),
            Event.Tag(name: "image", values: ["https://x/injected.png"]),
            Event.Tag(name: "description", values: ["injected"]),
            .hashtag("nostr"),
        ]

        let event = try await sign(set, with: signer)
        #expect(event.tags.filter { $0.name == "d" }.count == 1)
        #expect(event.tags.filter { $0.name == "title" }.count == 1)
        #expect(event.tags.filter { $0.name == "image" }.count == 1)
        #expect(event.tags.filter { $0.name == "description" }.count == 1)
        // The dedicated properties win; the injected reserved tags are discarded.
        let reread = try NostrListSet(event: event)
        #expect(reread.identifier == "reading")
        #expect(reread.title == "Reading")
        #expect(reread.imageURL == "https://x/cover.png")
        #expect(reread.publicItems == [.hashtag("nostr")])
    }
}
