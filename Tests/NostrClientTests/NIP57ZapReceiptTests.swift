import Foundation
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
        return try signer.sign(UnsignedEvent(pubkey: signer.publicKey, kind: .zap, rawTags: tags, content: ""))
    }

    /// Builds a JSON-encoded kind-9734 zap request with the given amount and, optionally, zapped event.
    private func zapRequestJSON(recipient: String, amountMillisats: Int64?, eventId: String? = nil) throws
        -> String
    {
        let sender = EventSigner(keyPair: try KeyPair())
        let request = try sender.signZapRequest(
            recipientPubkey: recipient, relays: ["wss://relay.example.com"],
            amountMillisats: amountMillisats, eventId: eventId)
        return String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    // MARK: - Success

    @Test("a valid receipt passes validation and exposes its fields")
    func validReceipt() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
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
            lnurlProviderPubkey: payee.publicKeyHex, expectedAmountMillisats: coffeeAmountMillisats)

        #expect(zapReceipt.bolt11 == coffeeInvoice)
        #expect(zapReceipt.recipientPubkey == recipient)
        #expect(zapReceipt.amountMillisats == coffeeAmountMillisats)
        #expect(zapReceipt.zapRequest?.kind == .zapRequest)
    }

    @Test("an amountless invoice does not fail the amount check")
    func amountlessReceipt() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: nil)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", amountlessInvoice],
                ["description", description],
                ["p", recipient],
            ])

        // Even with an expected amount, an amountless invoice is advisory and must not fail.
        try ZapReceipt(event: receipt)!.validate(
            lnurlProviderPubkey: payee.publicKeyHex, expectedAmountMillisats: 999_999)
    }

    // MARK: - Structural failures

    @Test("init returns nil for a non-9735 event")
    func initRejectsWrongKind() throws {
        let note = try EventSigner(keyPair: try KeyPair()).signTextNote(content: "hi")
        #expect(ZapReceipt(event: note) == nil)
    }

    @Test("a receipt signed by another key fails payeePubkeyMismatch")
    func payeeMismatch() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        let otherPubkey = try KeyPair().publicKeyHex
        #expect(throws: ZapReceipt.ValidationError.payeePubkeyMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: otherPubkey)
        }
    }

    @Test("a tampered signature fails invalidSignature")
    func invalidSignature() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
            ])

        // Flip the first hex character of the signature — still well-formed, but invalid.
        let replacement: Character = receipt.sig.first == "a" ? "b" : "a"
        let badSig = String(replacement) + receipt.sig.dropFirst()
        let tampered = Event(
            id: receipt.id, pubkey: receipt.pubkey, createdAt: receipt.createdAt, kind: receipt.kind,
            tags: receipt.tags, content: receipt.content, sig: badSig)

        #expect(throws: ZapReceipt.ValidationError.invalidSignature) {
            try ZapReceipt(event: tampered)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("a receipt without a bolt11 tag fails missingBolt11")
    func missingBolt11() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [["description", description], ["p", recipient]])

        #expect(throws: ZapReceipt.ValidationError.missingBolt11) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("a receipt without a description tag fails missingDescription")
    func missingDescription() throws {
        let payee = try KeyPair()
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [["bolt11", coffeeInvoice], ["p", try KeyPair().publicKeyHex]])

        #expect(throws: ZapReceipt.ValidationError.missingDescription) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("an unparseable bolt11 fails invalidBolt11")
    func invalidBolt11() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", "not a valid bolt11"],
                ["description", description],
                ["p", recipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.invalidBolt11) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    // MARK: - Semantic failures

    @Test("a description not matching the invoice hash fails descriptionHashMismatch")
    func descriptionHashMismatch() throws {
        let payee = try KeyPair()
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", descriptionHashInvoice],
                ["description", "this is not the hashed description"],
                ["p", try KeyPair().publicKeyHex],
            ])

        #expect(throws: ZapReceipt.ValidationError.descriptionHashMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("a zap request amount differing from the invoice fails amountMismatch")
    func amountMismatch() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
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
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("an expected amount differing from the invoice fails amountMismatch")
    func expectedAmountMismatch() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
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
                lnurlProviderPubkey: payee.publicKeyHex, expectedAmountMillisats: 1)
        }
    }

    @Test("a receipt recipient differing from the zap request fails recipientMismatch")
    func recipientMismatch() throws {
        let payee = try KeyPair()
        let requestRecipient = try KeyPair().publicKeyHex
        let receiptRecipient = try KeyPair().publicKeyHex  // a different recipient
        let description = try zapRequestJSON(recipient: requestRecipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", receiptRecipient],
            ])

        #expect(throws: ZapReceipt.ValidationError.recipientMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("a receipt zapped-event differing from the zap request fails zappedEventMismatch")
    func zappedEventMismatch() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(
            recipient: recipient, amountMillisats: coffeeAmountMillisats, eventId: "eventInRequest")
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", coffeeInvoice],
                ["description", description],
                ["p", recipient],
                ["e", "aDifferentEvent"],
            ])

        #expect(throws: ZapReceipt.ValidationError.zappedEventMismatch) {
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("an invalid signature is reported even when the bolt11 is also unparseable")
    func invalidSignatureTakesPrecedenceOverBolt11() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
        let description = try zapRequestJSON(recipient: recipient, amountMillisats: coffeeAmountMillisats)
        let receipt = try makeReceipt(
            signedBy: payee,
            tags: [
                ["bolt11", "not a valid bolt11"],
                ["description", description],
                ["p", recipient],
            ])
        let replacement: Character = receipt.sig.first == "a" ? "b" : "a"
        let badSig = String(replacement) + receipt.sig.dropFirst()
        let tampered = Event(
            id: receipt.id, pubkey: receipt.pubkey, createdAt: receipt.createdAt, kind: receipt.kind,
            tags: receipt.tags, content: receipt.content, sig: badSig)

        #expect(throws: ZapReceipt.ValidationError.invalidSignature) {
            try ZapReceipt(event: tampered)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }

    @Test("a wrong preimage fails preimageMismatch")
    func preimageMismatch() throws {
        let payee = try KeyPair()
        let recipient = try KeyPair().publicKeyHex
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
            try ZapReceipt(event: receipt)!.validate(lnurlProviderPubkey: payee.publicKeyHex)
        }
    }
}
