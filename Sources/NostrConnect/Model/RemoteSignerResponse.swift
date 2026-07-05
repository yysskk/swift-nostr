/// The JSON body of a NIP-46 response: `{"id": ..., "result": ..., "error": ...}`.
///
/// The ``id`` matches the request it answers. On success ``result`` holds the method's result
/// string and ``error`` is absent; on failure ``error`` holds a human-readable message. The body is
/// decoded from the NIP-44 decrypted content of a kind 24133 response event.
struct RemoteSignerResponse: Codable, Sendable, Hashable {
    /// The id of the request this response answers.
    let id: String
    /// The method result, or `"auth_url"` for an authentication challenge; absent on error.
    let result: String?
    /// A human-readable error message, or the challenge URL when ``isAuthChallenge`` is true.
    let error: String?

    /// Whether this is an `auth_url` challenge (``result`` is `"auth_url"` with the URL in
    /// ``error``).
    var isAuthChallenge: Bool { result == "auth_url" && error != nil }
}
