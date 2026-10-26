import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NIP-51 List Tests")
struct NIP51ListTests {

    // MARK: - Kind

    @Test("Bookmark list kind is 10003 and replaceable")
    func bookmarkListKind() {
        #expect(Event.Kind.bookmarkList.rawValue == 10003)
        #expect(Event.Kind.bookmarkList.isReplaceable)
    }

    // MARK: - Tag constructors

    @Test("word tag")
    func wordTag() {
        #expect(Event.Tag.word("nostr").rawArray == ["word", "nostr"])
    }

    @Test("address tag without relay")
    func addressTag() {
        #expect(
            Event.Tag.address(kind: .longFormContent, publicKey: .fixture("pk"), identifier: "d").rawArray
                == ["a", "30023:\(PublicKey.fixture("pk").hex):d"]
        )
    }

    @Test("address tag with relay")
    func addressTagWithRelay() {
        #expect(
            Event.Tag.address(
                kind: .longFormContent, publicKey: .fixture("pk"), identifier: "d", relayURL: RelayURL("wss://r")!
            ).rawArray == ["a", "30023:\(PublicKey.fixture("pk").hex):d", "wss://r"]
        )
    }

    @Test("reference tag")
    func referenceTag() {
        #expect(Event.Tag.reference("https://x").rawArray == ["r", "https://x"])
    }

    // MARK: - list(_:encryptingWith:) / init(event:decryptingWith:) round-trip

    /// Builds `list`'s template, encrypting with `signer`, and signs it with the same signer.
    private func sign(_ list: NostrList, with signer: some NostrSigning) async throws -> Event {
        try await signer.sign(EventTemplate.list(list, encryptingWith: signer))
    }

    @Test("list(_:encryptingWith:) carries the kind and public items, and only encrypted private items")
    func listTemplateLayout() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let publicItems: [Event.Tag] = [.event(EventID.fixture("public-note-id")), .hashtag("nostr")]
        let list = NostrList(kind: .bookmarkList, publicItems: publicItems, privateItems: [.word("secret")])

        let template = try await EventTemplate.list(list, encryptingWith: signer)

        #expect(template.kind == .bookmarkList)
        #expect(template.tags == publicItems)
        #expect(
            try ListItemCipher.items(fromJSON: signer.nip44Decrypt(template.content, from: signer.publicKey))
                == [.word("secret")])
    }

    @Test(
        "A list round-trips its private items through a local and a remote signer",
        arguments: [false, true]
    )
    func signOpenRoundTrip(remote: Bool) async throws {
        let keyPair = try KeyPair()
        let signer: any NostrSigning = remote ? StubRemoteSigner(keyPair: keyPair) : EventSigner(keyPair: keyPair)
        let publicItems: [Event.Tag] = [.event(EventID.fixture("public-note-id")), .hashtag("nostr")]
        let privateItems: [Event.Tag] = [.event(EventID.fixture("private-note-id")), .word("secret-word")]
        let list = NostrList(kind: .bookmarkList, publicItems: publicItems, privateItems: privateItems)

        let event = try await sign(list, with: signer)
        #expect(event.kind == .bookmarkList)
        #expect(event.publicKey == keyPair.publicKey)
        #expect(try event.verify())

        let opened = try await NostrList(event: event, decryptingWith: signer)
        #expect(opened.kind == .bookmarkList)
        #expect(opened.publicItems == publicItems)
        #expect(opened.privateItems == privateItems)
    }

    @Test("Empty private items leave content empty without asking the signer to encrypt")
    func emptyPrivateItems() async throws {
        let list = NostrList(kind: .muteList, publicItems: [.word("spam")])

        let template = try await EventTemplate.list(list, encryptingWith: FailingSigner())
        #expect(template.content == "")

        // Reading empty content back needs no decryption either.
        let event = try await EventSigner(keyPair: try KeyPair()).sign(template)
        let opened = try await NostrList(event: event, decryptingWith: FailingSigner())
        #expect(opened.privateItems.isEmpty)
        #expect(opened.publicItems == [.word("spam")])
    }

    @Test("Non-empty private items produce a base64 payload without the plaintext")
    func encryptedContentHidesPlaintext() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        // Use distinctive multi-character strings: their appearance in the base64 payload would
        // signal a leak, while being long enough not to collide with random nonce/ciphertext bytes.
        let list = NostrList(
            kind: .muteList,
            privateItems: [Event.Tag(name: "muted-word-tag", values: ["confidential-secret-value"])]
        )

        let event = try await sign(list, with: signer)
        #expect(!event.content.isEmpty)
        // The content is a decodable base64 NIP-44 payload...
        #expect(Data(base64Encoded: event.content) != nil)
        // ...and it must not leak the plaintext tag name or value.
        #expect(!event.content.contains("muted-word-tag"))
        #expect(!event.content.contains("confidential-secret-value"))
    }

    @Test("A signer error while encrypting propagates")
    func encryptionFailurePropagates() async throws {
        let list = NostrList(kind: .muteList, privateItems: [.word("secret-word")])

        await #expect(throws: NostrError.timeout) {
            try await EventTemplate.list(list, encryptingWith: FailingSigner())
        }
    }

    // MARK: - init(event:decryptingWith:) errors

    @Test("A different signer cannot decrypt the list")
    func differentSignerCannotOpen() async throws {
        let author = EventSigner(keyPair: try KeyPair())
        let other = EventSigner(keyPair: try KeyPair())
        let list = NostrList(kind: .muteList, privateItems: [.word("secret-word")])

        let event = try await sign(list, with: author)
        await #expect(throws: (any Error).self) {
            try await NostrList(event: event, decryptingWith: other)
        }
    }

    @Test("Content that decrypts to something other than a tag array throws decryptionFailed")
    func nonTagArrayContentThrows() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let content = try signer.nip44Encrypt(#"{"not":"a tag array"}"#, to: signer.publicKey)
        let event = try await signer.sign(EventTemplate(kind: .muteList, content: content))

        await #expect(throws: NostrError.decryptionFailed) {
            try await NostrList(event: event, decryptingWith: signer)
        }
    }

    @Test("A signer error while decrypting propagates")
    func decryptionFailurePropagates() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try await sign(NostrList(kind: .muteList, privateItems: [.word("secret-word")]), with: signer)

        await #expect(throws: NostrError.timeout) {
            try await NostrList(event: event, decryptingWith: FailingSigner())
        }
    }

    // MARK: - Lossless read-modify-write

    @Test("Unusual public tags survive a read-modify-write cycle")
    func losslessPublicItems() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let unusual = Event.Tag(name: "client", values: ["x"])
        let list = NostrList(kind: .bookmarkList, publicItems: [.hashtag("nostr"), unusual])

        let event = try await sign(list, with: signer)
        let reread = NostrList(event: event)
        #expect(reread.publicItems.contains(unusual))

        let resigned = try await sign(reread, with: signer)
        #expect(NostrList(event: resigned).publicItems == list.publicItems)
    }

    @Test("NostrList(event:) exposes only public items")
    func eventInitPublicOnly() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let list = NostrList(
            kind: .bookmarkList,
            publicItems: [.hashtag("nostr")],
            privateItems: [.word("secret-word")]
        )

        let event = try await sign(list, with: signer)
        let publicView = NostrList(event: event)
        #expect(publicView.kind == .bookmarkList)
        #expect(publicView.publicItems == list.publicItems)
        #expect(publicView.privateItems.isEmpty)
    }
}
