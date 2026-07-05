import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-56 Report Tests")
struct NIP56ReportTests {

    @Test("report type raw values match the spec strings")
    func reportTypeRawValues() {
        #expect(
            ReportType.allCases.map(\.rawValue) == [
                "nudity", "malware", "profanity", "illegal", "spam", "impersonation", "other",
            ])
    }

    @Test("signReport(pubkey:) produces a kind-1984 event with the type on the p tag")
    func signPubkeyReport() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let target = try KeyPair()

        let event = try signer.signReport(pubkey: target.publicKeyHex, type: .nudity, reason: "explicit content")

        #expect(event.kind == .report)
        #expect(event.content == "explicit content")
        #expect(event.tags.contains(["p", target.publicKeyHex, "nudity"]))
        #expect(try event.verify())
    }

    @Test("signReport(pubkey:) supports impersonation, the spec's canonical example")
    func signImpersonationReport() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let target = try KeyPair()

        let event = try signer.signReport(pubkey: target.publicKeyHex, type: .impersonation)

        #expect(event.kind == .report)
        #expect(event.content.isEmpty)
        #expect(event.tags.contains(["p", target.publicKeyHex, "impersonation"]))
        #expect(try event.verify())
    }

    @Test("signReport(event:) tags the event with a type and names the author with a bare p tag")
    func signEventReport() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let note = try author.signTextNote(content: "offending note")

        let reporter = EventSigner(keyPair: try KeyPair())
        let event = try reporter.signReport(event: note, type: .illegal, reason: "against the law")

        #expect(event.kind == .report)
        #expect(event.content == "against the law")
        #expect(event.tags.contains(["e", note.id, "illegal"]))
        // The author is named by a bare "p" tag carrying no report type.
        let authorTag = event.tags(named: "p").first
        #expect(authorTag?.rawArray == ["p", note.pubkey])
        #expect(try event.verify())
    }

    @Test("signReport(event:) keeps the author p tag even when the reason is empty")
    func signEventReportWithoutReason() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let note = try author.signTextNote(content: "offending note")

        let reporter = EventSigner(keyPair: try KeyPair())
        let event = try reporter.signReport(event: note, type: .spam)

        #expect(event.content.isEmpty)
        #expect(event.tags.contains(["e", note.id, "spam"]))
        let authorTag: Event.Tag? = event.tags(named: "p").first
        #expect(authorTag?.rawArray == ["p", note.pubkey])
        #expect(try event.verify())
    }

    @Test("publishReport(pubkey:) without a signer throws signerNotSet")
    func publishReportWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()

        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.publishReport(pubkey: "deadbeef", type: .spam)
        }
    }
}
