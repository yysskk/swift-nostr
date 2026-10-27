import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NIP-40 Expiration Tests")
struct NIP40ExpirationTests {

    // MARK: - Tag and accessors

    @Test("expiration tag carries the Unix timestamp in seconds")
    func expirationTag() {
        #expect(Tag.expiration(Timestamp(rawValue: 1_700_000_000)).rawArray == ["expiration", "1700000000"])
    }

    @Test("an expiration from a date drops sub-second precision")
    func expirationTagTruncates() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.9)
        #expect(Tag.expiration(Timestamp(date)).rawArray == ["expiration", "1700000000"])
    }

    @Test("Event.expiration reads a valid expiration tag")
    func eventExpiration() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let expiry = Timestamp(rawValue: 1_700_000_000)
        let event = signer.sign(.textNote("gm", tags: [.expiration(expiry)]))
        #expect(event.expiration == expiry)
    }

    @Test("Event.expiration is nil without an expiration tag")
    func eventExpirationAbsent() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.textNote("gm"))
        #expect(event.expiration == nil)
    }

    @Test("Event.expiration is nil for a non-integer value")
    func eventExpirationInvalid() {
        let event = Event(
            id: EventID.fixture("x"), publicKey: PublicKey.fixture("p"), createdAt: Timestamp(rawValue: 0),
            kind: .textNote, tags: [["expiration", "soon"]], content: "", signature: nil
        )
        #expect(event.expiration == nil)
    }

    @Test("isExpired compares against the given time, expiring at the boundary")
    func isExpired() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.textNote("gm", tags: [.expiration(Timestamp(rawValue: 1000))]))
        #expect(event.isExpired(asOf: Timestamp(rawValue: 1001)))
        #expect(event.isExpired(asOf: Timestamp(rawValue: 1000)))
        #expect(!event.isExpired(asOf: Timestamp(rawValue: 999)))
    }

    @Test("an event without an expiration tag never expires")
    func noExpirationNeverExpires() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.textNote("gm"))
        #expect(!event.isExpired(asOf: Timestamp(rawValue: 9_999_999_999)))
    }

    // MARK: - Disappearing direct messages

    @Test("a disappearing DM carries the expiration on the gift wrap, not the rumor")
    func dmGiftWrapCarriesExpiration() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let expiry = Timestamp(rawValue: 1_700_000_000)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createMessageWithSelfCopy(
            content: "self-destructs", to: recipient.publicKey, expiration: expiry)

        // The public gift wraps carry the expiration; the encrypted rumor stays untouched
        // so the plaintext leaks nothing.
        #expect(result.recipientGiftWrap.expiration == expiry)
        #expect(result.selfGiftWrap.expiration == expiry)
        #expect(result.rumor.expiration == nil)
    }

    @Test("a received disappearing DM exposes its expiration")
    func parsedDMExposesExpiration() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let expiry = Timestamp(rawValue: 1_700_000_000)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createMessageWithSelfCopy(
            content: "self-destructs", to: recipient.publicKey, expiration: expiry)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let message = try await parser.parse(result.recipientGiftWrap)
        #expect(message.expiresAt == expiry)
        #expect(message.content == "self-destructs")
    }

    @Test("a received DM keeps the rumor's created_at and an expiration beyond Date's range exactly")
    func parsedDMKeepsTimestampsExactly() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()
        let expiry = Timestamp(rawValue: .max)

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createMessageWithSelfCopy(
            content: "far future", to: recipient.publicKey, expiration: expiry)
        #expect(result.recipientGiftWrap.firstTagValue(named: "expiration") == "9223372036854775807")

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let message = try await parser.parse(result.recipientGiftWrap)
        #expect(message.expiresAt == expiry)
        // The gift wrap's own created_at is randomized; the message reports the rumor's.
        #expect(message.createdAt == result.rumor.createdAt)
    }

    @Test("a normal DM has no expiration")
    func normalDMHasNoExpiration() async throws {
        let sender = KeyPair()
        let recipient = KeyPair()

        let builder = DirectMessageBuilder(signer: EventSigner(keyPair: sender))
        let result = try await builder.createMessageWithSelfCopy(content: "hi", to: recipient.publicKey)

        #expect(result.recipientGiftWrap.expiration == nil)

        let parser = DirectMessageParser(signer: EventSigner(keyPair: recipient))
        let message = try await parser.parse(result.recipientGiftWrap)
        #expect(message.expiresAt == nil)
    }
}
