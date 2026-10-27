import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrWalletConnect

@Suite("WalletInfo Tests")
struct WalletInfoTests {
    private func infoEvent(content: String, tags: [Event.Tag] = []) -> Event {
        Event(
            id: .fixture("info"),
            publicKey: .fixture("wallet"),
            createdAt: Timestamp(rawValue: 0),
            kind: .walletConnectInfo,
            tags: tags,
            content: content,
            signature: nil)
    }

    @Test("keeps every advertised method token, recognized or not, in order")
    func parsesMethods() throws {
        let event = infoEvent(content: "pay_invoice get_balance future_method  make_invoice")
        let info = try #require(WalletInfo(infoEvent: event))
        let futureMethod = WalletConnectMethod(rawValue: "future_method")
        #expect(info.methods == [.payInvoice, .getBalance, futureMethod, .makeInvoice])
        #expect(info.supports(.payInvoice))
        #expect(info.supports(futureMethod))
        #expect(!info.supports(.payKeysend))
    }

    @Test("prefers NIP-44 when both schemes are advertised")
    func prefersNIP44() throws {
        let event = infoEvent(content: "pay_invoice", tags: [Event.Tag(name: "encryption", values: ["nip44_v2 nip04"])])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip44, .nip04])
        #expect(info.negotiatedEncryption == .nip44)
    }

    @Test("defaults to NIP-04 when no encryption tag is present")
    func defaultsToNIP04() throws {
        let info = try #require(WalletInfo(infoEvent: infoEvent(content: "pay_invoice")))
        #expect(info.encryptions == [.nip04])
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("uses NIP-04 when only NIP-04 is advertised")
    func onlyNIP04() throws {
        let event = infoEvent(content: "pay_invoice", tags: [Event.Tag(name: "encryption", values: ["nip04"])])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("accepts nip44 as an alias for nip44_v2")
    func nip44Alias() throws {
        let event = infoEvent(content: "pay_invoice", tags: [Event.Tag(name: "encryption", values: ["nip44"])])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip44])
        #expect(info.negotiatedEncryption == .nip44)
    }

    @Test("falls back to NIP-04 when only unrecognized schemes are advertised")
    func unknownSchemesFallBack() throws {
        let event = infoEvent(content: "pay_invoice", tags: [Event.Tag(name: "encryption", values: ["nip44_v99"])])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip04])
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("parses the notifications tag")
    func parsesNotifications() throws {
        let event = infoEvent(
            content: "pay_invoice", tags: [Event.Tag(name: "notifications", values: ["payment_received payment_sent"])])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.notifications == ["payment_received", "payment_sent"])
    }

    @Test("returns nil for a non-info event")
    func rejectsWrongKind() {
        let event = Event(
            id: .fixture("info"),
            publicKey: .fixture("wallet"),
            createdAt: Timestamp(rawValue: 0),
            kind: .textNote,
            tags: [],
            content: "pay_invoice",
            signature: nil)
        #expect(WalletInfo(infoEvent: event) == nil)
    }
}
