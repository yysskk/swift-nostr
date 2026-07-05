import Foundation
import NostrCore

@testable import NostrConnect

/// Helpers for driving a ``RemoteSigner`` from the signer side in tests.
///
/// A fake remote-signer keypair decrypts the client's request event and crafts an encrypted
/// response event delivered via ``FakeRemoteSignerTransport``.
enum RemoteSignerFixtures {
    /// A malformed fixture input (e.g. a `sign_event` request with no parameter).
    struct MalformedFixture: Error {}

    /// Builds a `bunker://` token pointing at `signer`, with an optional connection secret.
    static func bunker(signer: KeyPair, secret: String? = nil) throws -> BunkerURI {
        try BunkerURI(
            remoteSignerPubkey: signer.publicKeyHex,
            relays: [URL(string: "wss://relay.example")!],
            secret: secret)
    }

    /// Decrypts a request event the client sent to the signer, returning the request body.
    static func decryptRequest(_ event: Event, client: KeyPair, signer: KeyPair) throws -> RemoteSignerRequest {
        let json = try SealedMessage(payload: event.content).open(from: client.publicKeyHex, using: signer)
        return try JSONDecoder().decode(RemoteSignerRequest.self, from: Data(json.utf8))
    }

    /// Builds a kind-24133 response event for `requestID`, encrypting the given body to the client.
    ///
    /// `result` and `error` map straight onto the response JSON; pass `result: "auth_url"` with an
    /// `error` URL to simulate an authentication challenge.
    static func response(
        requestID: String, result: String? = nil, error: String? = nil, client: KeyPair, signer: KeyPair
    ) throws -> Event {
        var object: [String: Any] = ["id": requestID]
        if let result { object["result"] = result }
        if let error { object["error"] = error }
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        let sealed = try SealedMessage.seal(json, for: client.publicKeyHex, using: signer)
        return Event(
            id: "resp-\(requestID)",
            pubkey: signer.publicKeyHex,
            createdAt: 0,
            kind: .nostrConnect,
            tags: [["p", client.publicKeyHex]],
            content: sealed.payload,
            sig: "")
    }

    /// Signs `unsigned` with the fake signer, producing the JSON-stringified signed event a
    /// `sign_event` response carries as its result.
    static func signedEventJSON(_ unsigned: UnsignedEvent, signer: KeyPair) throws -> String {
        let signed = try EventSigner(keyPair: signer).sign(unsigned)
        let data = try JSONEncoder().encode(signed)
        return String(decoding: data, as: UTF8.self)
    }

    /// Reconstructs the unsigned event a `sign_event` request carries in its first parameter, as the
    /// signer would to sign it. Uses the client's pubkey as the author.
    static func unsignedEvent(from request: RemoteSignerRequest, author: String) throws -> UnsignedEvent {
        guard let param = request.params.first,
            let object = try JSONSerialization.jsonObject(with: Data(param.utf8)) as? [String: Any]
        else {
            throw MalformedFixture()
        }
        let kind = Event.Kind(rawValue: object["kind"] as? Int ?? 0)
        let content = object["content"] as? String ?? ""
        let createdAt = (object["created_at"] as? Int).map(Int64.init) ?? 0
        let tags = object["tags"] as? [[String]] ?? []
        return UnsignedEvent(pubkey: author, createdAt: createdAt, kind: kind, rawTags: tags, content: content)
    }

    /// Polls until `transport` has recorded at least `count` sent events, returning them.
    static func waitForSentEvents(_ transport: FakeRemoteSignerTransport, count: Int) async throws -> [Event] {
        for _ in 0..<400 {
            let sent = await transport.sentEvents
            if sent.count >= count { return sent }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RemoteSignerError.timedOut
    }
}
