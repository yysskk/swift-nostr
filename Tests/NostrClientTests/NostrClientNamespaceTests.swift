import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NostrClient Namespace Tests")
struct NostrClientNamespaceTests {

    // MARK: - Namespaces address one client

    @Test("every namespace addresses the same client")
    func namespacesShareTheClient() async throws {
        let (client, _) = try await ConnectedClientFixture.make()

        // Reading a namespace twice yields two values that reach the same actor.
        #expect(await client.relays.relayCount == 1)
        #expect(await client.relays.pool.relayCount == 1)

        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)
        // A signer installed through one namespace is visible from the others.
        #expect(await client.identity.publicKey != nil)
        #expect(await client.hasSigner)

        await client.relays.disconnect()
    }

    @Test("relays.pool is the injected pool, not a copy")
    func relaysPoolIsTheInjectedPool() async throws {
        let pool = RelayPool(config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig))
        let client = NostrClient(relayPool: pool)

        #expect(client.relays.pool === pool)

        // The one relay entry point stays in sync with the pool it wraps.
        await client.relays.add(RelayURL("wss://relay.example.com")!)
        #expect(await pool.relayCount == 1)
        #expect(await client.relays.relayCount == 1)
    }

    // MARK: - Capability protocols

    @Test("a feature can depend on one capability instead of the whole client")
    func capabilityProtocolDrivesAPublish() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)

        // The shape an app feature would hold: one namespace behind its protocol.
        let publishing: any NostrEventPublishing = client.events

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            // Through the protocol every argument is explicit: Swift forbids default
            // values on protocol requirements, so the namespace supplies them and the
            // existential does not.
            try await publishing.publishTextNote(content: "via a capability", tags: [], strategy: nil)
        }

        #expect(published.event.content == "via a capability")
        #expect(published.event.kind == .textNote)
        await client.relays.disconnect()
    }

    @Test("identity conforms to NostrIdentityProviding end to end")
    func identityCapability() async throws {
        let (client, _) = try await ConnectedClientFixture.make()
        let identity: any NostrIdentityProviding = client.identity
        let keyPair = try KeyPair()

        #expect(await identity.publicKey == nil)
        try await identity.setPrivateKey(keyPair.privateKeyHex)

        #expect(await identity.publicKey == keyPair.publicKey)
        #expect(await identity.authenticationMode == .automatic)

        await identity.setAuthenticationMode(.manual)
        #expect(await identity.authenticationMode == .manual)

        let signed = try await identity.sign(
            UnsignedEvent(publicKey: keyPair.publicKey, kind: .textNote, content: "signed")
        )
        #expect(try signed.verify())

        let peer = try KeyPair()
        let payload = try await identity.nip44Encrypt("sealed", to: peer.publicKey)
        #expect(try EventSigner(keyPair: peer).nip44Decrypt(payload, from: keyPair.publicKey) == "sealed")
        #expect(try await identity.nip44Decrypt(payload, from: peer.publicKey) == "sealed")

        await client.relays.disconnect()
    }

    @Test("relays conforms to NostrRelayManaging end to end")
    func relaysCapability() async throws {
        let relays: any NostrRelayManaging = NostrClient(
            relayPool: RelayPool(config: RelayPoolConfig(defaultRelayConfig: ConnectedClientFixture.noReconnectConfig))
        ).relays

        await relays.add([RelayURL("wss://relay1.example.com")!, RelayURL("wss://relay2.example.com")!])
        #expect(await relays.relayCount == 2)
        #expect(await relays.connectedRelayCount() == 0)
        #expect(await relays.relay(for: RelayURL("wss://relay1.example.com")!) != nil)

        await relays.remove(RelayURL("wss://relay1.example.com")!)
        #expect(await relays.relayCount == 1)
        #expect(await relays.connections.count == 1)
    }

    @Test("subscriptions conforms to NostrSubscribing end to end")
    func subscriptionsCapability() async throws {
        let (client, _) = try await ConnectedClientFixture.make()
        let subscriptions: any NostrSubscribing = client.subscriptions

        let subscription = try await subscriptions.subscribe(
            filters: [Filter(kinds: [.textNote], limit: 1)],
            to: nil,
            bufferingPolicy: .unbounded
        )
        #expect(await client.activeSubscriptionCount == 1)

        await subscriptions.unsubscribe(subscriptionID: subscription.id)
        #expect(await client.activeSubscriptionCount == 0)

        _ = try await subscriptions.globalFeed(limit: 1)
        await subscriptions.unsubscribeAll()
        #expect(await client.activeSubscriptionCount == 0)

        await client.relays.disconnect()
    }

    @Test("events conforms to NostrEventFetching end to end")
    func eventFetchingCapability() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        let fetching: any NostrEventFetching = client.events
        let author = try KeyPair()
        let note = try EventSigner(keyPair: author).signTextNote(content: "stored")

        let events = try await answering(socket, with: [note]) {
            try await fetching.fetch(filters: [Filter(kinds: [.textNote])], from: nil, timeout: .seconds(5))
        }

        #expect(events.map(\.content) == ["stored"])
        await client.relays.disconnect()
    }

    @Test("routing conforms to NostrRelayRouting end to end")
    func relayRoutingCapability() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)
        let routing: any NostrRelayRouting = client.routing

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await routing.publishRelayList(
                read: [RelayURL("wss://read.example.com")!], write: [RelayURL("wss://write.example.com")!],
                strategy: nil)
        }

        #expect(published.event.kind == .relayListMetadata)
        // Publishing seeds the cache, so the author's list resolves without a network round trip.
        let cached = await routing.cachedRelayList(for: published.event.publicKey)
        #expect(cached?.writeRelays == [RelayURL("wss://write.example.com")!])
        await client.relays.disconnect()
    }

    @Test("messages conforms to NostrMessaging end to end")
    func messagingCapability() async throws {
        let (client, _) = try await ConnectedClientFixture.make()
        let recipient = try KeyPair()
        try await client.identity.setPrivateKey(recipient.privateKeyHex)
        let messaging: any NostrMessaging = client.messages

        let sender = try KeyPair()
        let sent = try await DirectMessageBuilder(signer: EventSigner(keyPair: sender))
            .createMessageWithSelfCopy(content: "through the protocol", to: recipient.publicKey)

        let parsed = try await messaging.parse(sent.recipientGiftWrap)

        #expect(parsed.content == "through the protocol")
        #expect(parsed.senderPubkey == sender.publicKey)
        await client.relays.disconnect()
    }

    @Test("groups conforms to NostrGroupManaging end to end")
    func groupManagingCapability() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)
        let groups: any NostrGroupManaging = client.groups
        let list = SimpleGroupList(
            publicEntries: [GroupListEntry(groupID: "abc", relayURL: RelayURL("wss://groups.example.com")!)])

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await groups.publishSimpleGroupList(list, strategy: nil)
        }

        #expect(published.event.kind == .simpleGroupList)
        #expect(try SimpleGroupList(list: NostrList(event: published.event)).publicEntries == list.publicEntries)
        await client.relays.disconnect()
    }

    @Test("lists conforms to NostrListManaging end to end")
    func listManagingCapability() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)
        let lists: any NostrListManaging = client.lists
        let bookmarks = NostrList(kind: .bookmarkList, publicItems: [.event(.fixture("note"))])

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await lists.publish(bookmarks, strategy: nil)
        }

        #expect(published.event.kind == .bookmarkList)
        #expect(NostrList(event: published.event).publicItems == bookmarks.publicItems)
        await client.relays.disconnect()
    }

    // MARK: - Namespaces are values

    @Test("a namespace is Sendable and survives being handed to another task")
    func namespaceCrossesTaskBoundaries() async throws {
        let (client, socket) = try await ConnectedClientFixture.make()
        try await client.identity.setPrivateKey(try KeyPair().privateKeyHex)
        let events = client.events

        let published = try await PublishAckSupport.acknowledgingPublishes(on: socket) {
            try await Task { try await events.publishTextNote(content: "from another task") }.value
        }

        #expect(published.event.content == "from another task")
        await client.relays.disconnect()
    }

    // MARK: - Private

    /// Runs `fetch` while answering the socket's REQ with the canned `events` and an EOSE,
    /// so a one-time fetch completes without a live relay.
    private func answering<T: Sendable>(
        _ socket: MockWebSocketSession,
        with events: [Event],
        during fetch: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let task = Task { try await fetch() }
        try await NIP42TestSupport.pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"REQ\"") } }
        guard let frame = socket.sentTextFrames.first(where: { $0.hasPrefix("[\"REQ\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            let subscriptionID = array.count >= 2 ? array[1] as? String : nil
        else {
            throw NostrError.invalidMessageFormat
        }
        for event in events {
            let json = String(decoding: try JSONEncoder().encode(event), as: UTF8.self)
            socket.deliver(.string("[\"EVENT\",\"\(subscriptionID)\",\(json)]"))
        }
        socket.deliver(.string("[\"EOSE\",\"\(subscriptionID)\"]"))
        return try await task.value
    }
}
