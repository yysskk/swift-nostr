import Foundation
import NostrCore

@testable import NostrWalletConnect

/// Helpers for driving a ``WalletConnection`` from the wallet side in tests.
enum NWCFixtures {
    static func uri(wallet: KeyPair, client: KeyPair) throws -> WalletConnectURI {
        try WalletConnectURI(
            walletPubkey: wallet.publicKeyHex,
            relays: [URL(string: "wss://relay.example")!],
            secret: client.privateKey)
    }

    /// Encrypts a payload from `sender` to `recipient` with the given scheme.
    static func encrypt(
        _ json: String, to recipient: KeyPair, from sender: KeyPair, scheme: WalletConnectEncryption = .nip44
    ) throws -> String {
        try WalletConnectCipher(scheme).encrypt(json, recipientPubkey: recipient.publicKeyHex, sender: sender)
    }

    /// Decrypts a request event the client sent to the wallet.
    static func decryptRequest(
        _ event: Event, client: KeyPair, wallet: KeyPair, scheme: WalletConnectEncryption = .nip44
    ) throws -> String {
        try WalletConnectCipher(scheme).decrypt(event.content, senderPubkey: client.publicKeyHex, recipient: wallet)
    }

    /// Builds a signed kind-23195 response event for a request, encrypting `resultJSON` to the
    /// client.
    ///
    /// Signed by the wallet key, as a real response is: the connection verifies a response before
    /// reading anything in it, so an unsigned fixture would not stand in for one.
    static func response(
        resultJSON: String, requestID: String, client: KeyPair, wallet: KeyPair,
        scheme: WalletConnectEncryption = .nip44, dTag: String? = nil,
        declaringEncryption: Bool = false
    ) throws -> Event {
        var tags = [["e", requestID], ["p", client.publicKeyHex]]
        if let dTag { tags.append(["d", dTag]) }
        if declaringEncryption { tags.append(["encryption", scheme.rawValue]) }
        return try signed(
            kind: .walletConnectResponse,
            tags: tags,
            content: try encrypt(resultJSON, to: client, from: wallet, scheme: scheme),
            wallet: wallet)
    }

    /// Signs `content` as `wallet`, so the event carries the id and signature the connection checks.
    static func signed(
        kind: Event.Kind, tags: [[String]], content: String, wallet: KeyPair, createdAt: Int64 = 0
    ) throws -> Event {
        try EventSigner(keyPair: wallet).sign(
            UnsignedEvent(
                pubkey: wallet.publicKeyHex, createdAt: createdAt, kind: kind, rawTags: tags,
                content: content))
    }

    /// Builds a notification event of the given kind, encrypting `notificationJSON` to the client.
    static func notification(
        notificationJSON: String, kind: Event.Kind, client: KeyPair, wallet: KeyPair,
        scheme: WalletConnectEncryption
    ) throws -> Event {
        try signed(
            kind: kind,
            tags: [["p", client.publicKeyHex]],
            content: try encrypt(notificationJSON, to: client, from: wallet, scheme: scheme),
            wallet: wallet)
    }

    /// Builds a signed kind-13194 info event.
    static func info(content: String, tags: [[String]], wallet: KeyPair) throws -> Event {
        try signed(kind: .walletConnectInfo, tags: tags, content: content, wallet: wallet)
    }

    /// Polls until `transport` has recorded at least `count` sent events, returning them.
    static func waitForSentEvents(_ transport: FakeWalletConnectTransport, count: Int) async throws -> [Event] {
        for _ in 0..<400 {
            let sent = await transport.sentEvents
            if sent.count >= count { return sent }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WalletConnectError.timedOut
    }

    /// Polls until `transport` has entered `connect()` at least `count` times.
    static func waitForConnectAttempts(_ transport: FakeWalletConnectTransport, count: Int) async throws {
        for _ in 0..<400 {
            if await transport.connectCount >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw WalletConnectError.timedOut
    }
}
