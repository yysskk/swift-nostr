import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletInfo Tests")
struct WalletInfoTests {
    private func infoEvent(content: String, tags: [[String]] = []) -> Event {
        Event(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "0", count: 64),
            createdAt: 0,
            kind: .walletConnectInfo,
            tags: tags,
            content: content,
            sig: "")
    }

    @Test("parses supported and unknown methods from the content")
    func parsesMethods() throws {
        let event = infoEvent(content: "pay_invoice get_balance make_invoice future_method")
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.methods == [.payInvoice, .getBalance, .makeInvoice])
        #expect(info.unknownMethods == ["future_method"])
        #expect(info.supports(.payInvoice))
        #expect(!info.supports(.payKeysend))
    }

    @Test("prefers NIP-44 when both schemes are advertised")
    func prefersNip44() throws {
        let event = infoEvent(content: "pay_invoice", tags: [["encryption", "nip44_v2 nip04"]])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip44, .nip04])
        #expect(info.negotiatedEncryption == .nip44)
    }

    @Test("defaults to NIP-04 when no encryption tag is present")
    func defaultsToNip04() throws {
        let info = try #require(WalletInfo(infoEvent: infoEvent(content: "pay_invoice")))
        #expect(info.encryptions == [.nip04])
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("uses NIP-04 when only NIP-04 is advertised")
    func onlyNip04() throws {
        let event = infoEvent(content: "pay_invoice", tags: [["encryption", "nip04"]])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("accepts nip44 as an alias for nip44_v2")
    func nip44Alias() throws {
        let event = infoEvent(content: "pay_invoice", tags: [["encryption", "nip44"]])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip44])
        #expect(info.negotiatedEncryption == .nip44)
    }

    @Test("falls back to NIP-04 when only unrecognized schemes are advertised")
    func unknownSchemesFallBack() throws {
        let event = infoEvent(content: "pay_invoice", tags: [["encryption", "nip44_v99"]])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.encryptions == [.nip04])
        #expect(info.negotiatedEncryption == .nip04)
    }

    @Test("parses the notifications tag")
    func parsesNotifications() throws {
        let event = infoEvent(content: "pay_invoice", tags: [["notifications", "payment_received payment_sent"]])
        let info = try #require(WalletInfo(infoEvent: event))
        #expect(info.notifications == ["payment_received", "payment_sent"])
    }

    @Test("returns nil for a non-info event")
    func rejectsWrongKind() {
        let event = Event(
            id: String(repeating: "0", count: 64),
            pubkey: String(repeating: "0", count: 64),
            createdAt: 0,
            kind: .textNote,
            tags: [],
            content: "pay_invoice",
            sig: "")
        #expect(WalletInfo(infoEvent: event) == nil)
    }
}
