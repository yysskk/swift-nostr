import Foundation
import NostrCore
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
            Event.Tag.address(kind: .longFormContent, pubkey: "pk", identifier: "d").rawArray
                == ["a", "30023:pk:d"]
        )
    }

    @Test("address tag with relay")
    func addressTagWithRelay() {
        #expect(
            Event.Tag.address(kind: .longFormContent, pubkey: "pk", identifier: "d", relayURL: "wss://r").rawArray
                == ["a", "30023:pk:d", "wss://r"]
        )
    }

    @Test("reference tag")
    func referenceTag() {
        #expect(Event.Tag.reference("https://x").rawArray == ["r", "https://x"])
    }

    // MARK: - signList / openList round-trip

    @Test("signList then openList restores public and private items")
    func signOpenRoundTrip() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let publicItems: [Event.Tag] = [.event("public-note-id"), .hashtag("nostr")]
        let privateItems: [Event.Tag] = [.event("private-note-id"), .word("secret-word")]
        let list = NostrList(kind: .bookmarkList, publicItems: publicItems, privateItems: privateItems)

        let event = try signer.signList(list)
        #expect(event.kind == .bookmarkList)
        #expect(try event.verify())

        let opened = try signer.openList(event)
        #expect(opened.kind == .bookmarkList)
        #expect(opened.publicItems == publicItems)
        #expect(opened.privateItems == privateItems)
    }

    @Test("Empty private items leave content empty")
    func emptyPrivateItems() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let list = NostrList(kind: .muteList, publicItems: [.word("spam")])

        let event = try signer.signList(list)
        #expect(event.content == "")
    }

    @Test("Non-empty private items produce a base64 payload without the plaintext")
    func encryptedContentHidesPlaintext() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        // Use distinctive multi-character strings: their appearance in the base64 payload would
        // signal a leak, while being long enough not to collide with random nonce/ciphertext bytes.
        let list = NostrList(
            kind: .muteList,
            privateItems: [Event.Tag(name: "muted-word-tag", values: ["confidential-secret-value"])]
        )

        let event = try signer.signList(list)
        #expect(!event.content.isEmpty)
        // The content is a decodable base64 NIP-44 payload...
        #expect(Data(base64Encoded: event.content) != nil)
        // ...and it must not leak the plaintext tag name or value.
        #expect(!event.content.contains("muted-word-tag"))
        #expect(!event.content.contains("confidential-secret-value"))
    }

    @Test("A different signer cannot open the list")
    func differentSignerCannotOpen() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let other = EventSigner(keyPair: try KeyPair())
        let list = NostrList(kind: .muteList, privateItems: [.word("secret-word")])

        let event = try author.signList(list)
        #expect(throws: (any Error).self) {
            try other.openList(event)
        }
    }

    // MARK: - Lossless read-modify-write

    @Test("Unusual public tags survive a read-modify-write cycle")
    func losslessPublicItems() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let unusual = Event.Tag(name: "client", values: ["x"])
        let list = NostrList(kind: .bookmarkList, publicItems: [.hashtag("nostr"), unusual])

        let event = try signer.signList(list)
        let reread = NostrList(event: event)
        #expect(reread.publicItems.contains(unusual))

        let resigned = try signer.signList(reread)
        #expect(NostrList(event: resigned).publicItems == list.publicItems)
    }

    @Test("NostrList(event:) exposes only public items")
    func eventInitPublicOnly() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let list = NostrList(
            kind: .bookmarkList,
            publicItems: [.hashtag("nostr")],
            privateItems: [.word("secret-word")]
        )

        let event = try signer.signList(list)
        let publicView = NostrList(event: event)
        #expect(publicView.kind == .bookmarkList)
        #expect(publicView.publicItems == list.publicItems)
        #expect(publicView.privateItems.isEmpty)
    }
}
