/// The JSON body of a NIP-46 request: `{"id": ..., "method": ..., "params": [...]}`.
///
/// Every parameter is a string; the meaning of each position depends on ``method``. The body is
/// NIP-44 encrypted into the content of a kind 24133 request event.
struct RemoteSignerRequest: Codable, Sendable, Hashable {
    /// A correlation id echoed back on the matching response.
    let id: String
    /// The remote-signing method to invoke.
    let method: String
    /// The positional string arguments for the method.
    let params: [String]

    init(id: String = RemoteSignerRequest.makeID(), method: RemoteSignerMethod, params: [String]) {
        self.id = id
        self.method = method.rawValue
        self.params = params
    }

    /// A random request id (16 random bytes, hex-encoded).
    static func makeID() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
