import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NIP-57 Zap Receipt Tests")
struct NIP57ZapReceiptTests {

    // Canonical BOLT-11 vectors reused as receipt invoices.
    // 2500u coffee: amount 250,000,000 msats, a payment hash, and a `d` description (no `h`).
    private let coffeeInvoice =
        "lnbc2500u1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdq5xysxxatsyp3k7enxv4jsxqzpu9qrsgquk0rl77nj30yxdy8j9vdx85fkpmdla2087ne0xh8nhedh8w27kyke0lp53ut353s06fv3qfegext0eh0ymjpf39tuven09sam30g4vgpfna3rh"
    private let coffeeAmountMillisats: Int64 = 250_000_000
    // 20m invoice carrying a description-hash `h` field.
    private let descriptionHashInvoice =
        "lnbc20m1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqhp58yjmdan79s6qqdhdzgynm4zwqd5d7xmw5fk98klysy043l2ahrqs9qrsgq7ea976txfraylvgzuxs8kgcw23ezlrszfnh8r6qtfpr6cxga50aj6txm9rxrydzd06dfeawfk6swupvz4erwnyutnjq7x39ymw6j38gp7ynn44"
    // Amountless donation invoice (no amount, `d` description).
    private let amountlessInvoice =
        "lnbc1pvjluezsp5zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygspp5qqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqqqsyqcyq5rqwzqfqypqdpl2pkx2ctnv5sxxmmwwd5kgetjypeh2ursdae8g6twvus8g6rfwvs8qun0dfjkxaq9qrsgq357wnc5r2ueh7ck6q93dj32dlqnls087fxdwk8qakdyafkq3yap9us6v52vjjsrvywa6rt52cm9r9zqt8r2t7mlcwspyetp5h2tztugp9lfyql"

    // MARK: - Helpers

    /// Builds a signed kind-9735 receipt with the given raw tags, signed by `payee`.
    private func makeReceipt(signedBy payee: KeyPair, tags: [[String]]) throws -> Event {
        let signer = EventSigner(keyPair: payee)
        return try signer.sign(
            UnsignedEvent(
                publicKey: signer.publicKey, kind: .zap, tags: tags.map(Event.Tag.init(rawArray:)), content: ""))
    }

    /// Builds a JSON-encoded kind-9734 zap request with the given amount and, optionally, zapped event.
    private func zapRequestJSON(recipient: String, amountMillisats: Int64?, eventID: String? = nil) throws
        -> String
    {
        let sender = EventSigner(keyPair: KeyPair())
        let request = try sender.sign(
            .zapRequest(
                to: try PublicKey(hex: recipient), relays: [RelayURL("wss://relay.example.com")!],
                amountMillisats: amountMillisats, eventID: try eventID.map(EventID.init(hex:))))
        return String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    // MARK: - Success

    /// The canonical BOLT-11 vectors used here carry a plain `d` description rather than the
    /// description hash a real LNURL-pay invoice commits to, so the binding check is relaxed for
    /// them. `descriptionHashRequiredByDefault` below covers the default.
    @Test("a valid receipt passes validation and exposes its fields")
    func validReceipt() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        let zapReceipt = try #require(ZapReceipt(event: receipt))
        try zapReceipt.validate(
            lnurlProviderPublicKey: payee.publicKey,
            expectedAmountMillisats: coffeeAmountMillisats,
            requiringDescriptionHash: false)

        #expect(zapReceipt.bolt11 == coffeeInvoice)
        #expect(zapReceipt.recipientPublicKey?.hex == recipient)
        #expect(zapReceipt.amountMillisats == coffeeAmountMillisats)
        #expect(zapReceipt.zapRequest?.kind == .zapRequest)
    }

    @Test("an amountless invoice passes when no amount is asserted")
    func amountlessReceipt() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: nil)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", amountlessInvoice],
                ["description", description],
                ["p", recipient],
            ])

        try ZapReceipt(event: receipt)!.validate(
            lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
    }

    /// Asking for an amount that the invoice never names is a check that cannot be made. Passing
    /// silently told the caller their assertion held when nothing had been compared.
    @Test("an expected amount against an amountless invoice fails")
    func amountlessReceiptRejectsExpectedAmount() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: nil)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", amountlessInvoice],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.missingAmount) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey,
                expectedAmountMillisats: 999_999,
                requiringDescriptionHash: false)
        }
    }

    /// LUD-06 and LUD-12 make the description hash part of the LNURL-pay flow every zap goes
    /// through. Without it the receipt pairs an invoice and a zap request that need have nothing to
    /// do with each other, so `validate` no longer passes over its absence by default.
    @Test("an invoice with no description hash fails by default")
    func descriptionHashRequiredByDefault() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.missingDescriptionHash) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    /// NIP-57 requires the receipt to carry a `p` tag. Without one it never says who was zapped, so
    /// a receipt that passed validation proved only that the provider had signed something.
    @Test("a receipt without a p tag fails missingRecipient")
    func missingRecipient() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
            ])

        #expect(throws: ZapReceipt.ValidationError.missingRecipient) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    @Test("a receipt whose p tag is not a canonical hex key fails missingRecipient")
    func malformedRecipient() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient.uppercased()],
            ])

        let zapReceipt = try #require(ZapReceipt(event: receipt))
        #expect(zapReceipt.recipientPublicKey == nil)
        #expect(throws: ZapReceipt.ValidationError.missingRecipient) {
            try zapReceipt.validate(lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    @Test("the sender and zapped event read as typed values, and as nil when malformed")
    func typedSenderAndZappedEvent() throws {
        let payee = KeyPair()
        let sender = PublicKey.fixture("sender")
        let zapped = EventID.fixture("zapped")
        let wellFormed = try #require(
            ZapReceipt(event: try makeReceipt(signedBy: payee, tags: [["P", sender.hex], ["e", zapped.hex]])))
        let malformed = try #require(
            ZapReceipt(event: try makeReceipt(signedBy: payee, tags: [["P", "sender"], ["e", "zapped"]])))

        #expect(wellFormed.senderPublicKey == sender)
        #expect(wellFormed.zappedEventID == zapped)
        #expect(malformed.senderPublicKey == nil)
        #expect(malformed.zappedEventID == nil)
    }

    /// A non-numeric amount read as "no amount at all", quietly dropping the comparison against the
    /// invoice instead of reporting that the request was malformed.
    @Test("a non-numeric zap request amount fails invalidAmount")
    func invalidRequestAmount() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let sender = EventSigner(keyPair: KeyPair())
        let request = try sender.sign(
            UnsignedEvent(
                publicKey: sender.publicKey,
                kind: .zapRequest,
                tags: [
                    Event.Tag(name: .publicKey, values: [recipient]),
                    Event.Tag(name: "amount", values: ["not-a-number"]),
                ],
                content: ""
            ))
        let description = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.invalidAmount) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    // MARK: - Structural failures

    @Test("init returns nil for a non-9735 event")
    func initRejectsWrongKind() throws {
        let note = EventSigner(keyPair: KeyPair()).sign(.textNote("hi"))
        #expect(ZapReceipt(event: note) == nil)
    }

    @Test("a receipt signed by another key fails payeePublicKeyMismatch")
    func payeeMismatch() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        let otherPublicKey = KeyPair().publicKey
        #expect(throws: ZapReceipt.ValidationError.payeePublicKeyMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: otherPublicKey)
        }
    }

    @Test("a tampered signature fails invalidSignature")
    func invalidSignature() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        // Flip the first hex character of the signature — still well-formed, but invalid.
        let sig = try #require(receipt.signature).hex
        let replacement: Character = sig.first == "a" ? "b" : "a"
        let badSig = try Signature(hex: String(replacement) + sig.dropFirst())
        let tampered = Event(
            id: receipt.id, publicKey: receipt.publicKey, createdAt: receipt.createdAt, kind: receipt.kind,
            tags: receipt.tags, content: receipt.content, signature: badSig)

        #expect(throws: ZapReceipt.ValidationError.invalidSignature) {
            try ZapReceipt(event: tampered)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    @Test("a receipt without a bolt11 tag fails missingBolt11")
    func missingBolt11() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [["description", description], ["p", recipient]])

        #expect(throws: ZapReceipt.ValidationError.missingBolt11) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    @Test("a receipt without a description tag fails missingDescription")
    func missingDescription() throws {
        let payee = KeyPair()
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [["bolt11", coffeeInvoice], ["p", KeyPair().publicKey.hex]])

        #expect(throws: ZapReceipt.ValidationError.missingDescription) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    @Test("an unparseable bolt11 fails invalidBolt11")
    func invalidBolt11() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", "not a valid bolt11"],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.invalidBolt11) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    // MARK: - Semantic failures

    @Test("a description not matching the invoice hash fails descriptionHashMismatch")
    func descriptionHashMismatch() throws {
        let payee = KeyPair()
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", descriptionHashInvoice],
                ["description", "this is not the hashed description"],
                ["p", KeyPair().publicKey.hex],
            ])

        #expect(throws: ZapReceipt.ValidationError.descriptionHashMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    @Test("a zap request amount differing from the invoice fails amountMismatch")
    func amountMismatch() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        // The zap request asks for an amount the coffee invoice does not encode.
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: 12_345)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.amountMismatch) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    @Test("an expected amount differing from the invoice fails amountMismatch")
    func expectedAmountMismatch() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.amountMismatch) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey,
                expectedAmountMillisats: 1,
                requiringDescriptionHash: false)
        }
    }

    @Test("a receipt recipient differing from the zap request fails recipientMismatch")
    func recipientMismatch() throws {
        let payee = KeyPair()
        let requestRecipient = KeyPair().publicKey.hex
        let receiptRecipient = KeyPair().publicKey.hex  // a different recipient
        let description = try zapRequestJSON(recipient: requestRecipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", receiptRecipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.recipientMismatch) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    @Test("a receipt zapped-event differing from the zap request fails zappedEventMismatch")
    func zappedEventMismatch() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(
            recipient: recipient, amountMillisats: coffeeAmountMillisats, eventID: EventID.fixture("in request").hex)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
                ["e", EventID.fixture("a different event").hex],
            ])

        #expect(throws: ZapReceipt.ValidationError.zappedEventMismatch) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }

    @Test("an invalid signature is reported even when the bolt11 is also unparseable")
    func invalidSignatureTakesPrecedenceOverBolt11() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", "not a valid bolt11"],
                ["description", description],
                ["p", recipient],
            ])
        let sig = try #require(receipt.signature).hex
        let replacement: Character = sig.first == "a" ? "b" : "a"
        let badSig = try Signature(hex: String(replacement) + sig.dropFirst())
        let tampered = Event(
            id: receipt.id, publicKey: receipt.publicKey, createdAt: receipt.createdAt, kind: receipt.kind,
            tags: receipt.tags, content: receipt.content, signature: badSig)

        #expect(throws: ZapReceipt.ValidationError.invalidSignature) {
            try ZapReceipt(event: tampered)!.validate(lnurlProviderPublicKey: payee.publicKey)
        }
    }

    @Test("a wrong preimage fails preimageMismatch")
    func preimageMismatch() throws {
        let payee = KeyPair()
        let recipient = KeyPair().publicKey.hex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["preimage", String(repeating: "00", count: 32)],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.preimageMismatch) {
            try ZapReceipt(event: receipt)!.validate(
                lnurlProviderPublicKey: payee.publicKey, requiringDescriptionHash: false)
        }
    }
}
