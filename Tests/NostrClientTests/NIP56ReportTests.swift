import Foundation
import NostrCore
import NostrTestSupport
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

    @Test("report(_:type:reason:) of a public key produces a kind-1984 event with the type on the p tag")
    func signPublicKeyReport() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let target = try KeyPair()

        let event = try signer.sign(.report(target.publicKey, type: .nudity, reason: "explicit content"))

        #expect(event.kind == .report)
        #expect(event.content == "explicit content")
        #expect(event.tags.contains(["p", target.publicKey.hex, "nudity"]))
        #expect(try event.verify())
    }

    @Test("report(_:type:reason:) of a public key supports impersonation, the spec's canonical example")
    func signImpersonationReport() throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let target = try KeyPair()

        let event = try signer.sign(.report(target.publicKey, type: .impersonation))

        #expect(event.kind == .report)
        #expect(event.content.isEmpty)
        #expect(event.tags.contains(["p", target.publicKey.hex, "impersonation"]))
        #expect(try event.verify())
    }

    @Test("report(_:type:reason:) of an event tags the event with a type and names the author with a bare p tag")
    func signEventReport() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let note = try author.sign(.textNote("offending note"))

        let reporter = EventSigner(keyPair: try KeyPair())
        let event = try reporter.sign(.report(note, type: .illegal, reason: "against the law"))

        #expect(event.kind == .report)
        #expect(event.content == "against the law")
        #expect(event.tags.contains(["e", note.id.hex, "illegal"]))
        // The author is named by a bare "p" tag carrying no report type.
        let authorTag = event.tags(named: "p").first
        #expect(authorTag?.rawArray == ["p", note.publicKey.hex])
        #expect(try event.verify())
    }

    @Test("report(_:type:reason:) of an event keeps the author p tag even when the reason is empty")
    func signEventReportWithoutReason() throws {
        let author = EventSigner(keyPair: try KeyPair())
        let note = try author.sign(.textNote("offending note"))

        let reporter = EventSigner(keyPair: try KeyPair())
        let event = try reporter.sign(.report(note, type: .spam))

        #expect(event.content.isEmpty)
        #expect(event.tags.contains(["e", note.id.hex, "spam"]))
        let authorTag: Event.Tag? = event.tags(named: "p").first
        #expect(authorTag?.rawArray == ["p", note.publicKey.hex])
        #expect(try event.verify())
    }

    @Test("publishReport(publicKey:) without a signer throws signerNotSet")
    func publishReportWithoutSignerThrowsSignerNotSet() async throws {
        let client = NostrClient()

        await #expect(throws: NostrError.signerNotSet) {
            _ = try await client.events.publishReport(publicKey: .fixture("target"), type: .spam)
        }
    }
}
