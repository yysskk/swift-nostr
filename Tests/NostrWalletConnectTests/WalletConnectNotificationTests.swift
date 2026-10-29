import Foundation
import NostrCore
import Testing

@testable import NostrWalletConnect

@Suite("WalletConnection Notification & Info Tests")
struct WalletConnectNotificationTests {
    @Test("notifications stream decrypts NIP-44 and NIP-04 events")
    func notificationsStream() async throws {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)

        var iterator = await connection.notifications().makeAsyncIterator()
        try await connection.connect()

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON:
                    #"{"notification_type":"payment_received","notification":{"type":"incoming","amount":1000,"payment_hash":"aa"}}"#,
                kind: .walletConnectNotification, client: client, wallet: wallet, scheme: .nip44))
        let received = await iterator.next()
        #expect(received?.type == .paymentReceived)
        #expect(received?.transaction?.amount == 1000)

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON:
                    #"{"notification_type":"payment_sent","notification":{"type":"outgoing","amount":2000,"payment_hash":"bb"}}"#,
                kind: .walletConnectNotificationLegacy, client: client, wallet: wallet, scheme: .nip04))
        let sent = await iterator.next()
        #expect(sent?.type == .paymentSent)
        #expect(sent?.transaction?.amount == 2000)
    }

    @Test("notifications() registers a stream without connecting", .timeLimit(.minutes(1)))
    func notificationsDoesNotConnect() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport)

        _ = await connection.notifications()

        #expect(await transport.connectCount == 0)
        #expect(await transport.subscriptions.isEmpty)
    }

    @Test(
        "connect() alone delivers notifications, and disconnect() ends the stream",
        .timeLimit(.minutes(1)))
    func connectAloneDeliversNotifications() async throws {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)
        let notifications = await connection.notifications()

        // connect() returns once the response-and-notification subscription is in place.
        try await connection.connect()
        let filters = try #require(await transport.subscriptions["nwc-responses"])
        let kinds = filters.first?.kinds ?? []
        #expect(kinds.contains(.walletConnectNotification))
        #expect(kinds.contains(.walletConnectNotificationLegacy))

        let notification = try NWCFixtures.notification(
            notificationJSON: #"{"notification_type":"payment_received","notification":{"amount":1000}}"#,
            kind: .walletConnectNotification, client: client, wallet: wallet, scheme: .nip44)
        await transport.emit(notification)

        var iterator = notifications.makeAsyncIterator()
        #expect(await iterator.next()?.type == .paymentReceived)
        #expect(await transport.sentEvents.isEmpty)

        await connection.disconnect()
        #expect(await iterator.next() == nil)
    }

    @Test("a notification type with no constant is kept, along with its raw payload")
    func unknownNotificationType() throws {
        let notification = try #require(
            WalletConnectNotification(
                content: #"{"notification_type":"hold_invoice_accepted","notification":{"payment_hash":"aa"}}"#))
        #expect(notification.type == WalletConnectNotificationType(rawValue: "hold_invoice_accepted"))
        #expect(notification.transaction == nil)
        #expect(notification.raw["payment_hash"] == .string("aa"))
    }

    @Test("a payment notification keeps a transaction type it has no constant for")
    func unknownTransactionTypeInNotification() throws {
        let notification = try #require(
            WalletConnectNotification(
                content: #"{"notification_type":"payment_received","notification":{"type":"internal","amount":1}}"#))
        #expect(notification.type == .paymentReceived)
        #expect(notification.transaction?.type == TransactionType(rawValue: "internal"))
    }

    @Test("fetchCapabilities returns and caches the parsed capabilities")
    func fetchCapabilitiesCaches() async throws {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)

        async let capabilitiesTask = connection.fetchCapabilities()
        // Wait until the info subscription is registered, then deliver the info event.
        for _ in 0..<400 where await transport.subscriptions["nwc-info"] == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        await transport.emit(
            try NWCFixtures.info(
                content: "pay_invoice get_balance",
                tags: [
                    Event.Tag(name: "encryption", values: ["nip44_v2 nip04"]),
                    Event.Tag(name: "notifications", values: ["payment_received"]),
                ],
                wallet: wallet))

        let capabilities = try await capabilitiesTask
        #expect(capabilities.methods == [.payInvoice, .getBalance])
        #expect(capabilities.encryptions == [.nip44, .nip04])
        #expect(capabilities.notifications == [.paymentReceived])
        #expect(capabilities.negotiatedEncryption == .nip44)
        #expect(await connection.capabilities == capabilities)
    }

    /// No info event can arrive once the relays' streams have ended, so the wait fails then rather
    /// than when its timeout elapses.
    /// The timeout is long enough to tell the two apart, yet bounds the run if this regresses.
    @Test("fetchCapabilities fails when the relays' event stream ends", .timeLimit(.minutes(1)))
    func fetchCapabilitiesFailsWhenEventStreamEnds() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let info = Task { try await connection.fetchCapabilities() }
        try await waitForInfoSubscription(transport)
        await transport.endEvents()

        await #expect(throws: WalletConnectError.notConnected) { try await info.value }
    }

    @Test("fetchCapabilities fails when the connection disconnects", .timeLimit(.minutes(1)))
    func fetchCapabilitiesFailsOnDisconnect() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let info = Task { try await connection.fetchCapabilities() }
        try await waitForInfoSubscription(transport)
        await connection.disconnect()

        await #expect(throws: WalletConnectError.notConnected) { try await info.value }
    }

    @Test("cancelling fetchCapabilities fails it with cancelled at once", .timeLimit(.minutes(1)))
    func fetchCapabilitiesCancellation() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let info = Task { try await connection.fetchCapabilities() }
        try await waitForInfoSubscription(transport)
        info.cancel()

        await #expect(throws: WalletConnectError.cancelled) { try await info.value }
    }

    // MARK: - Concurrent fetches

    @Test("concurrent fetchCapabilities calls share one info subscription", .timeLimit(.minutes(1)))
    func concurrentFetchesShareOneSubscription() async throws {
        let wallet = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let first = Task { try await connection.fetchCapabilities() }
        let second = Task { try await connection.fetchCapabilities() }
        try await waitForCapabilitiesWaiters(connection, count: 2)
        try await waitForInfoSubscription(transport)

        let info = try NWCFixtures.info(content: "pay_invoice get_balance", tags: [], wallet: wallet)
        await transport.emit(info)

        let firstCapabilities = try await first.value
        let secondCapabilities = try await second.value
        #expect(firstCapabilities.methods == [.payInvoice, .getBalance])
        #expect(secondCapabilities == firstCapabilities)
        #expect(await transport.subscribeCounts["nwc-info"] == 1)
    }

    @Test("concurrent fetchCapabilities calls both fail when the connection disconnects", .timeLimit(.minutes(1)))
    func concurrentFetchesShareFailure() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let first = Task { try await connection.fetchCapabilities() }
        let second = Task { try await connection.fetchCapabilities() }
        try await waitForCapabilitiesWaiters(connection, count: 2)
        try await waitForInfoSubscription(transport)
        await connection.disconnect()

        await #expect(throws: WalletConnectError.notConnected) { try await first.value }
        await #expect(throws: WalletConnectError.notConnected) { try await second.value }
    }

    @Test("cancelling one of two fetchCapabilities calls leaves the other", .timeLimit(.minutes(1)))
    func cancellingOneFetchLeavesTheOther() async throws {
        let wallet = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: KeyPair()), transport: transport,
            config: .init(requestTimeout: .seconds(20)))

        let cancelled = Task { try await connection.fetchCapabilities() }
        let survivor = Task { try await connection.fetchCapabilities() }
        try await waitForCapabilitiesWaiters(connection, count: 2)
        try await waitForInfoSubscription(transport)

        cancelled.cancel()
        await #expect(throws: WalletConnectError.cancelled) { try await cancelled.value }
        #expect(await connection.capabilitiesWaiterCountForTesting == 1)

        let info = try NWCFixtures.info(content: "pay_invoice", tags: [], wallet: wallet)
        await transport.emit(info)

        let capabilities = try await survivor.value
        #expect(capabilities.methods == [.payInvoice])
        #expect(await transport.subscribeCounts["nwc-info"] == 1)
    }

    // MARK: - Stream lifetime

    /// The merged event stream ends when every relay's has — automatic reconnection gave up, or the
    /// connections went away. No notification can arrive after that, so a stream left open would
    /// keep its consumer's `for await` loop suspended forever, with nothing saying why.
    @Test("notification streams finish when the relays' event stream ends", .timeLimit(.minutes(1)))
    func notificationStreamsFinishWhenEventStreamEnds() async throws {
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: KeyPair(), client: KeyPair()), transport: transport)
        let first = await connection.notifications()
        let second = await connection.notifications()
        try await connection.connect()
        let drained = Task {
            var received = 0
            for await _ in first { received += 1 }
            return received
        }

        await transport.endEvents()

        #expect(await drained.value == 0)
        var iterator = second.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test(
        "a stream opened after the event stream ended is live once connect() reconnects",
        .timeLimit(.minutes(1)))
    func notificationsAfterEventStreamEndedReconnects() async throws {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)
        let ended = await connection.notifications()
        try await connection.connect()
        await transport.endEvents()
        for await _ in ended {}

        var iterator = await connection.notifications().makeAsyncIterator()
        #expect(await transport.connectCount == 1)
        try await connection.connect()
        #expect(await transport.connectCount == 2)

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON: #"{"notification_type":"payment_received","notification":{"amount":1000}}"#,
                kind: .walletConnectNotification, client: client, wallet: wallet, scheme: .nip44))
        #expect(await iterator.next()?.type == .paymentReceived)
    }

    @Test("disconnect finishes notification streams, and one opened afterwards stays live", .timeLimit(.minutes(1)))
    func disconnectFinishesNotificationStreams() async throws {
        let wallet = KeyPair()
        let client = KeyPair()
        let transport = FakeWalletConnectTransport()
        let connection = WalletConnection(
            uri: try NWCFixtures.uri(wallet: wallet, client: client), transport: transport)
        let old = await connection.notifications()
        try await connection.connect()
        await connection.disconnect()
        for await _ in old {}

        var iterator = await connection.notifications().makeAsyncIterator()
        // Reconnecting waits for the disconnected session's reader to wind down, so it cannot
        // finish the new stream afterwards.
        try await connection.connect()

        await transport.emit(
            try NWCFixtures.notification(
                notificationJSON: #"{"notification_type":"payment_sent","notification":{"amount":2000}}"#,
                kind: .walletConnectNotification, client: client, wallet: wallet, scheme: .nip44))
        #expect(await iterator.next()?.type == .paymentSent)
    }

    // MARK: - Helpers

    /// Polls until `count` ``WalletConnection/fetchCapabilities()`` callers are waiting on the
    /// fetch in flight.
    private func waitForCapabilitiesWaiters(_ connection: WalletConnection, count: Int) async throws {
        for _ in 0..<400 {
            if await connection.capabilitiesWaiterCountForTesting == count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WalletConnectError.timedOut
    }

    /// Polls until ``WalletConnection/fetchCapabilities()`` has subscribed for the info event, by
    /// which point its waiter is registered.
    private func waitForInfoSubscription(_ transport: FakeWalletConnectTransport) async throws {
        for _ in 0..<400 {
            if await transport.subscriptions["nwc-info"] != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WalletConnectError.timedOut
    }
}
