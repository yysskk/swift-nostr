import Foundation
public import NostrCore

/// The typed NIP-46 commands.
extension RemoteSigner {
    /// Signs `event` remotely (`sign_event`).
    ///
    /// The signer returns a complete signed event; this validates the returned event's id and
    /// signature and confirms its `publicKey`, `kind`, `content`, `tags`, and `createdAt` match the
    /// request, so a signer cannot substitute a different event or sign under a different key.
    /// - Parameter event: The unsigned event to sign. Its `publicKey` must be the user's public key
    ///   (from ``publicKey``); the returned event is rejected unless the signer authored it
    ///   under that key.
    /// - Returns: The signed ``Event``.
    /// - Throws: ``RemoteSignerError/responseDecodingFailed`` if the reply is not an event,
    ///   ``RemoteSignerError/responseValidationFailed`` if the returned event fails to verify or does
    ///   not match the request — including when `event` is keyed to another public key, since the
    ///   signer signs under the user's — or what ``send(_:params:)`` throws.
    public func sign(_ event: UnsignedEvent) async throws(RemoteSignerError) -> Event {
        let requestJSON = try encodeUnsignedEvent(event)
        let result = try await send(.signEvent, params: [requestJSON])

        guard let signed = try? JSONDecoder().decode(Event.self, from: Data(result.utf8)) else {
            throw RemoteSignerError.responseDecodingFailed
        }
        // isValid only proves the returned event is self-consistent (its id/sig match its own
        // public key), not that it was signed by the expected key. Require the signer to have authored
        // it under the public key the caller asked for, so a validly-signed event from a different key
        // cannot be substituted.
        guard signed.isValid,
            signed.publicKey == event.publicKey,
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
    /// - Throws: ``RemoteSignerError/responseValidationFailed`` if the reply is not `pong`, or what
    ///   ``send(_:params:)`` throws.
    public func ping() async throws(RemoteSignerError) {
        let result = try await send(.ping)
        guard result == "pong" else {
            throw RemoteSignerError.responseValidationFailed
        }
    }

    /// Encrypts `plaintext` for a third party using NIP-44 (`nip44_encrypt`); the signer performs it
    /// with the user's key.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - recipientPublicKey: The recipient's public key.
    /// - Returns: The NIP-44 ciphertext.
    /// - Throws: What ``send(_:params:)`` throws.
    public func nip44Encrypt(
        _ plaintext: String, to recipientPublicKey: PublicKey
    ) async throws(RemoteSignerError) -> String {
        try await send(.nip44Encrypt, params: [recipientPublicKey.hex, plaintext])
    }

    /// Decrypts a NIP-44 message from a third party (`nip44_decrypt`); the signer performs it with
    /// the user's key.
    /// - Parameters:
    ///   - ciphertext: The NIP-44 ciphertext to decrypt.
    ///   - senderPublicKey: The sender's public key.
    /// - Returns: The decrypted plaintext.
    /// - Throws: What ``send(_:params:)`` throws.
    public func nip44Decrypt(
        _ ciphertext: String, from senderPublicKey: PublicKey
    ) async throws(RemoteSignerError) -> String {
        try await send(.nip44Decrypt, params: [senderPublicKey.hex, ciphertext])
    }

    /// Encrypts `plaintext` for a third party using legacy NIP-04 (`nip04_encrypt`); the signer
    /// performs it with the user's key.
    /// - Parameters:
    ///   - plaintext: The message to encrypt.
    ///   - thirdPartyPublicKey: The recipient's public key.
    /// - Returns: The NIP-04 ciphertext.
    /// - Throws: What ``send(_:params:)`` throws.
    public func nip04Encrypt(
        _ plaintext: String, to thirdPartyPublicKey: PublicKey
    ) async throws(RemoteSignerError) -> String {
        try await send(.nip04Encrypt, params: [thirdPartyPublicKey.hex, plaintext])
    }

    /// Decrypts a legacy NIP-04 message from a third party (`nip04_decrypt`); the signer performs it
    /// with the user's key.
    /// - Parameters:
    ///   - ciphertext: The NIP-04 ciphertext to decrypt.
    ///   - thirdPartyPublicKey: The sender's public key.
    /// - Returns: The decrypted plaintext.
    /// - Throws: What ``send(_:params:)`` throws.
    public func nip04Decrypt(
        _ ciphertext: String, from thirdPartyPublicKey: PublicKey
    ) async throws(RemoteSignerError) -> String {
        try await send(.nip04Decrypt, params: [thirdPartyPublicKey.hex, ciphertext])
    }

    /// Asks the signer for its preferred relays (`switch_relays`).
    ///
    /// This only fetches the list: the session keeps using its current relays. The caller decides
    /// whether to move — NIP-46 says the client SHOULD switch — typically by building a new
    /// ``RemoteSigner`` on the returned relays with the same client key pair and connecting it.
    /// - Returns: The signer's preferred relays, or `nil` when it keeps the current set.
    /// - Throws: ``RemoteSignerError/responseDecodingFailed`` if the reply is neither a JSON array
    ///   of relay URLs nor `null`, or what ``send(_:params:)`` throws.
    public func fetchPreferredRelays() async throws(RemoteSignerError) -> [RelayURL]? {
        let result = try await send(.switchRelays)
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "null" else { return nil }
        guard let strings = try? JSONDecoder().decode([String].self, from: Data(result.utf8)) else {
            throw RemoteSignerError.responseDecodingFailed
        }
        // The signer chose these, and it is the same untrusted party whose relays are
        // validated on both URI paths. A compromised one could otherwise point the session at
        // `http://` or `file://`. An entry that is not a relay URL is reported rather than
        // quietly dropped, so a malformed response does not look like a shorter relay list.
        let urls = strings.compactMap(RelayURL.init)
        guard urls.count == strings.count else {
            throw RemoteSignerError.responseDecodingFailed
        }
        return urls
    }

    /// JSON-stringifies an unsigned event as `{kind, content, tags, created_at}` for `sign_event`.
    private func encodeUnsignedEvent(_ event: UnsignedEvent) throws(RemoteSignerError) -> String {
        let object: [String: Any] = [
            "kind": event.kind.rawValue,
            "content": event.content,
            "tags": event.tags.map(\.rawArray),
            "created_at": event.createdAt.rawValue,
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
