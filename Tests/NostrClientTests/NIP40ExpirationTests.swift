import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-40 Expiration Tests")
struct NIP40ExpirationTests {

    // MARK: - Tag and accessors

    @Test("expiration tag carries the Unix timestamp in seconds")
    func expirationTag() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(Tag.expiration(date).rawArray == ["expiration", "1700000000"])
    }

    @Test("expiration tag truncates sub-second precision")
    func expirationTagTruncates() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.9)
        #expect(Tag.expiration(date).rawArray == ["expiration", "1700000000"])
    }

    @Test("Event.expiration reads a valid expiration tag")
    func eventExpiration() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)
        let event = try signer.signTextNote(content: "gm", tags: [.expiration(expiry)])
        #expect(event.expiration == expiry)
    }

    @Test("Event.expiration is nil without an expiration tag")
    func eventExpirationAbsent() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signTextNote(content: "gm")
        #expect(event.expiration == nil)
    }

    @Test("Event.expiration is nil for a non-integer value")
    func eventExpirationInvalid() {
        let event = Event(
            id: "x", pubkey: "p", createdAt: 0, kind: .textNote,
            tags: [["expiration", "soon"]], content: "", sig: ""
        )
        #expect(event.expiration == nil)
    }

    @Test("isExpired compares against the given time, expiring at the boundary")
    func isExpired() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signTextNote(content: "gm", tags: [.expiration(Date(timeIntervalSince1970: 1000))])
        #expect(event.isExpired(asOf: Date(timeIntervalSince1970: 1001)))
        #expect(event.isExpired(asOf: Date(timeIntervalSince1970: 1000)))
        #expect(!event.isExpired(asOf: Date(timeIntervalSince1970: 999)))
    }

    @Test("an event without an expiration tag never expires")
    func noExpirationNeverExpires() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try signer.signTextNote(content: "gm")
        #expect(!event.isExpired(asOf: Date(timeIntervalSince1970: 9_999_999_999)))
    }

    // MARK: - Disappearing direct messages

    @Test("a disappearing DM carries the expiration on the gift wrap, not the rumor")
    func dmGiftWrapCarriesExpiration() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)

        let builder = DirectMessageBuilder(keyPair: sender)
        let result = try builder.createMessageWithSelfCopy(
            content: "self-destructs", to: recipient.publicKeyHex, expiration: expiry)

        // The public gift wraps carry the expiration; the encrypted rumor stays untouched
        // so the plaintext leaks nothing.
        #expect(result.recipientGiftWrap.expiration == expiry)
        #expect(result.selfGiftWrap.expiration == expiry)
        #expect(result.rumor.expiration == nil)
    }

    @Test("a received disappearing DM exposes its expiration")
    func parsedDMExposesExpiration() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()
        let expiry = Date(timeIntervalSince1970: 1_700_000_000)

        let builder = DirectMessageBuilder(keyPair: sender)
        let result = try builder.createMessageWithSelfCopy(
            content: "self-destructs", to: recipient.publicKeyHex, expiration: expiry)

        let parser = DirectMessageParser(keyPair: recipient)
        let message = try parser.parse(result.recipientGiftWrap)
        #expect(message.expiresAt == expiry)
        #expect(message.content == "self-destructs")
    }

    @Test("a normal DM has no expiration")
    func normalDMHasNoExpiration() throws {
        let sender = try KeyPair()
        let recipient = try KeyPair()

        let builder = DirectMessageBuilder(keyPair: sender)
        let result = try builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKeyHex)

        #expect(result.recipientGiftWrap.expiration == nil)

        let parser = DirectMessageParser(keyPair: recipient)
        let message = try parser.parse(result.recipientGiftWrap)
        #expect(message.expiresAt == nil)
    }
}
