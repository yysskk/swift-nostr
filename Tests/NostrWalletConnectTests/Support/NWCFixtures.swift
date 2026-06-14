import Foundation
import NostrClient

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

    /// Builds a kind-23195 response event for a request, encrypting `resultJSON` to the client.
    static func response(
        resultJSON: String, requestID: String, client: KeyPair, wallet: KeyPair,
        scheme: WalletConnectEncryption = .nip44, dTag: String? = nil
    ) throws -> Event {
        var tags = [["e", requestID], ["p", client.publicKeyHex]]
        if let dTag { tags.append(["d", dTag]) }
        return Event(
            id: "resp-\(requestID)-\(dTag ?? "")",
            pubkey: wallet.publicKeyHex,
            createdAt: 0,
            kind: .walletConnectResponse,
            tags: tags,
            content: try encrypt(resultJSON, to: client, from: wallet, scheme: scheme),
            sig: "")
    }

    /// Builds a notification event of the given kind, encrypting `notificationJSON` to the client.
    static func notification(
        notificationJSON: String, kind: Event.Kind, client: KeyPair, wallet: KeyPair,
        scheme: WalletConnectEncryption
    ) throws -> Event {
        Event(
            id: "notif-\(kind.rawValue)",
            pubkey: wallet.publicKeyHex,
            createdAt: 0,
            kind: kind,
            tags: [["p", client.publicKeyHex]],
            content: try encrypt(notificationJSON, to: client, from: wallet, scheme: scheme),
            sig: "")
    }

    /// Builds a kind-13194 info event.
    static func info(content: String, tags: [[String]], wallet: KeyPair) -> Event {
        Event(
            id: "info",
            pubkey: wallet.publicKeyHex,
            createdAt: 0,
            kind: .walletConnectInfo,
            tags: tags,
            content: content,
            sig: "")
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
}
