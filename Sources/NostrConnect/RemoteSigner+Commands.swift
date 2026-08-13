import Foundation
public import NostrCore

/// The typed NIP-46 commands.
extension RemoteSigner {
    /// Fetches (and caches) the user's public key (`get_public_key`).
    ///
    /// This may differ from ``remoteSignerPubkey`` — a signer can hold a key distinct from its own
    /// session identity. The result is cached, so subsequent calls return without another
    /// round-trip.
    /// - Returns: The user's public key (hex).
    public func userPublicKey() async throws -> String {
        if let cached = userPublicKeyIfCached { return cached }
        let pubkey = try await performSingle(method: .getPublicKey, params: [])
        cacheUserPublicKey(pubkey)
        return pubkey
    }

    /// Signs `event` remotely (`sign_event`).
    ///
    /// The signer returns a complete signed event; this validates the returned event's id and
    /// signature and confirms its `pubkey`, `kind`, `content`, `tags`, and `created_at` match the
    /// request, so a signer cannot substitute a different event or sign under a different key.
    /// - Parameter event: The unsigned event to sign. Its `pubkey` must be the user's public key
    ///   (from ``userPublicKey()``); the returned event is rejected unless the signer authored it
    ///   under that key.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``RemoteSignerError/responseValidationFailed`` if the returned event fails to
    ///   verify or does not match the request.
    public func sign(_ event: UnsignedEvent) async throws -> Event {
        let requestJSON = try encodeUnsignedEvent(event)
        let result = try await performSingle(method: .signEvent, params: [requestJSON])

        guard let signed = try? JSONDecoder().decode(Event.self, from: Data(result.utf8)) else {
            throw RemoteSignerError.responseDecodingFailed
        }
        // verify() only proves the returned event is self-consistent (its id/sig match its own
        // pubkey), not that it was signed by the expected key. Require the signer to have authored
        // it under the pubkey the caller asked for, so a validly-signed event from a different key
        // cannot be substituted.
        guard (try? signed.verify()) == true,
            signed.pubkey == event.pubkey,
            signed.kind == event.kind,
            signed.content == event.content,
            signed.tags == event.tags,
            signed.createdAt == event.createdAt
        else {
            throw RemoteSignerError.responseValidationFailed
        }
        return signed
    }

    /// Liveness check (`ping`); the signer replies with `pong`.
    /// - Throws: ``RemoteSignerError/responseValidationFailed`` if the reply is not `pong`.
    public func ping() async throws {
        let result = try await performSingle(method: .ping, params: [])
        guard result == "pong" else {
            throw RemoteSignerError.responseValidationFailed
        }
    }

    /// Encrypts `plaintext` for a third party using NIP-44 (`nip44_encrypt`); the signer performs it
    /// with the user's key.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - thirdPartyPubkey: The recipient's public key (hex).
    /// - Returns: The NIP-44 ciphertext.
    public func nip44Encrypt(_ plaintext: String, to thirdPartyPubkey: String) async throws -> String {
        try await performSingle(method: .nip44Encrypt, params: [thirdPartyPubkey, plaintext])
    }

    /// Decrypts a NIP-44 message from a third party (`nip44_decrypt`); the signer performs it with
    /// the user's key.
    /// - Parameters:
    ///   - ciphertext: The NIP-44 ciphertext to decrypt.
    ///   - thirdPartyPubkey: The sender's public key (hex).
    /// - Returns: The decrypted plaintext.
    public func nip44Decrypt(_ ciphertext: String, from thirdPartyPubkey: String) async throws -> String {
        try await performSingle(method: .nip44Decrypt, params: [thirdPartyPubkey, ciphertext])
    }

    /// Encrypts `plaintext` for a third party using legacy NIP-04 (`nip04_encrypt`); the signer
    /// performs it with the user's key.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - thirdPartyPubkey: The recipient's public key (hex).
    /// - Returns: The NIP-04 ciphertext.
    public func nip04Encrypt(_ plaintext: String, to thirdPartyPubkey: String) async throws -> String {
        try await performSingle(method: .nip04Encrypt, params: [thirdPartyPubkey, plaintext])
    }

    /// Decrypts a legacy NIP-04 message from a third party (`nip04_decrypt`); the signer performs it
    /// with the user's key.
    /// - Parameters:
    ///   - ciphertext: The NIP-04 ciphertext to decrypt.
    ///   - thirdPartyPubkey: The sender's public key (hex).
    /// - Returns: The decrypted plaintext.
    public func nip04Decrypt(_ ciphertext: String, from thirdPartyPubkey: String) async throws -> String {
        try await performSingle(method: .nip04Decrypt, params: [thirdPartyPubkey, ciphertext])
    }

    /// Asks the signer for its preferred relays (`switch_relays`).
    /// - Returns: The signer's preferred relays, or `nil` when it keeps the current set.
    /// - Throws: ``RemoteSignerError/responseDecodingFailed`` if the reply is neither a JSON array
    ///   of URLs nor `null`.
    public func switchRelays() async throws -> [URL]? {
        let result = try await performSingle(method: .switchRelays, params: [])
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null" else { return nil }
        guard let strings = try? JSONDecoder().decode([String].self, from: Data(result.utf8)) else {
            throw RemoteSignerError.responseDecodingFailed
        }
        // The signer chose these, and it is the same untrusted party whose relays are
        // scheme-checked on both URI paths. A compromised one could otherwise point the session at
        // `http://` or `file://`. An unparseable or non-WebSocket entry is reported rather than
        // quietly dropped, so a malformed response does not look like a shorter relay list.
        let urls = strings.compactMap { URL(string: $0) }
        guard urls.count == strings.count, urls.allSatisfy(URIQuery.isWebSocketURL) else {
            throw RemoteSignerError.responseDecodingFailed
        }
        return urls
    }

    /// JSON-stringifies an unsigned event as `{kind, content, tags, created_at}` for `sign_event`.
    private func encodeUnsignedEvent(_ event: UnsignedEvent) throws -> String {
        let object: [String: Any] = [
            "kind": event.kind.rawValue,
            "content": event.content,
            "tags": event.tags,
            "created_at": event.createdAt,
        ]
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else {
            throw RemoteSignerError.requestEncodingFailed
        }
        return String(decoding: data, as: UTF8.self)
    }
}
