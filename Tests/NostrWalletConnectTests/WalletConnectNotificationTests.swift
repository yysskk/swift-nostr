import Foundation
import NostrClient
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnection Notification & Info Tests")
struct WalletConnectNotificationTests {
    @Test("notifications stream decrypts NIP-44 and NIP-04 events")
    func notificationsStream() async throws {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)

        // notifications() auto-connects — no explicit connect() needed.
        var iterator = try await connection.notifications().makeAsyncIterator()

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON:
                    #"{"notification_type":"payment_received","notification":{"type":"incoming","amount":1000,"payment_hash":"aa"}}"#,
                kind: .walletConnectNotification, client: client, wallet: wallet, scheme: .nip44))
        let received = await iterator.next()
        #expect(received?.type == "payment_received")
        #expect(received?.transaction?.amount == 1000)

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON:
                    #"{"notification_type":"payment_sent","notification":{"type":"outgoing","amount":2000,"payment_hash":"bb"}}"#,
                kind: .walletConnectNotificationLegacy, client: client, wallet: wallet, scheme: .nip04))
        let sent = await iterator.next()
        #expect(sent?.type == "payment_sent")
        #expect(sent?.transaction?.amount == 2000)
    }

    @Test("fetchInfo returns and caches the parsed wallet info")
    func fetchInfoCaches() async throws {
        let wallet = try KeyPair()
        let client = try KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)

        async let infoTask = connection.fetchInfo()
        // Wait until the info subscription is registered, then deliver the info event.
        for _ in 0..<400 where await transport.subscriptions["nwc-info"] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await transport.emit(
            NWCFixtures.info(
                content: "pay_invoice get_balance",
                tags: [["encryption", "nip44_v2 nip04"], ["notifications", "payment_received"]],
                wallet: wallet))

        let info = try await infoTask
        #expect(info.methods.contains(.payInvoice))
        #expect(info.negotiatedEncryption == .nip44)
        #expect(await connection.info?.methods.contains(.getBalance) == true)
    }
}
