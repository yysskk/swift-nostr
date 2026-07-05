import Foundation

/// An authentication challenge issued by the remote signer while it holds a request: display
/// ``url`` to the user (typically in a browser) so they can approve the operation. The originating
/// request stays pending until the signer answers it once the user has responded.
public struct RemoteSignerAuthChallenge: Sendable, Hashable {
    /// The URL to present to the user to complete authentication.
    public let url: URL
    /// The method whose request triggered this challenge.
    public let method: RemoteSignerMethod
    /// The id of the request that remains pending until the challenge is resolved.
    public let requestID: String
}
