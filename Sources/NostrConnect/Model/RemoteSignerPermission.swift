import NostrCore

/// A NIP-46 permission token requested at connect time (the `perms` argument), e.g.
/// `sign_event:1` or `nip44_encrypt`.
///
/// A client lists the operations it needs so the remote signer can grant them up front; the token's
/// ``rawValue`` is the exact string sent on the wire, comma-joined with the others.
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public struct RemoteSignerPermission: Sendable, Hashable, RawRepresentable {
    /// The wire token for this permission.
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Permission to sign events, optionally restricted to a single kind (`sign_event:<kind>`).
    ///
    /// - Parameter kind: The event kind to allow, or `nil` to allow any kind.
    public static func signEvent(kind: Event.Kind? = nil) -> RemoteSignerPermission {
        if let kind {
            return RemoteSignerPermission(rawValue: "\(RemoteSignerMethod.signEvent.rawValue):\(kind.rawValue)")
        }
        return RemoteSignerPermission(rawValue: RemoteSignerMethod.signEvent.rawValue)
    }

    /// Permission to encrypt messages using NIP-44.
    public static let nip44Encrypt = RemoteSignerPermission(rawValue: RemoteSignerMethod.nip44Encrypt.rawValue)
    /// Permission to decrypt messages using NIP-44.
    public static let nip44Decrypt = RemoteSignerPermission(rawValue: RemoteSignerMethod.nip44Decrypt.rawValue)
    /// Permission to encrypt messages using NIP-04.
    public static let nip04Encrypt = RemoteSignerPermission(rawValue: RemoteSignerMethod.nip04Encrypt.rawValue)
    /// Permission to decrypt messages using NIP-04.
    public static let nip04Decrypt = RemoteSignerPermission(rawValue: RemoteSignerMethod.nip04Decrypt.rawValue)
    /// Permission to read the user public key.
    public static let getPublicKey = RemoteSignerPermission(rawValue: RemoteSignerMethod.getPublicKey.rawValue)
}
