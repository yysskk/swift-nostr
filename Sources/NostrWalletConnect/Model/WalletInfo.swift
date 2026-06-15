public import NostrCore

/// The capabilities a wallet service advertises in its NIP-47 info event (kind 13194).
///
/// The info event's content is a space-separated list of supported method names; its `encryption`
/// and `notifications` tags list the supported encryption schemes and notification types. A wallet
/// that omits the `encryption` tag is assumed to use NIP-04 (the spec's legacy default).
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public struct WalletInfo: Sendable, Hashable {
    /// The recognized commands the wallet supports.
    public let methods: [WalletConnectMethod]

    /// Method tokens advertised by the wallet that this library does not model.
    public let unknownMethods: [String]

    /// The encryption schemes the wallet supports. Never empty: defaults to `[.nip04]` when the
    /// wallet advertises no `encryption` tag.
    public let encryptions: [WalletConnectEncryption]

    /// The notification types the wallet emits (e.g. `"payment_received"`, `"payment_sent"`).
    public let notifications: [String]

    /// Parses a wallet info event.
    /// - Parameter infoEvent: A kind-13194 event. Returns `nil` for any other kind.
    public init?(infoEvent: Event) {
        guard infoEvent.kind == .walletConnectInfo else { return nil }

        var methods: [WalletConnectMethod] = []
        var unknownMethods: [String] = []
        for token in infoEvent.content.split(whereSeparator: \.isWhitespace).map(String.init) {
            if let method = WalletConnectMethod(rawValue: token) {
                methods.append(method)
            } else {
                unknownMethods.append(token)
            }
        }
        self.methods = methods
        self.unknownMethods = unknownMethods

        // A missing encryption tag — or a tag listing only unrecognized schemes (e.g. a future
        // nip44_v3) — means NIP-04 only (the spec's backward-compatible default), keeping
        // `encryptions` non-empty.
        if let value = infoEvent.firstTagValue(named: "encryption") {
            let parsed = Self.parseEncryptions(value)
            self.encryptions = parsed.isEmpty ? [.nip04] : parsed
        } else {
            self.encryptions = [.nip04]
        }

        if let value = infoEvent.firstTagValue(named: "notifications") {
            self.notifications = value.split(whereSeparator: \.isWhitespace).map(String.init)
        } else {
            self.notifications = []
        }
    }

    /// The encryption scheme a client should use with this wallet: NIP-44 when supported, otherwise
    /// NIP-04. (NIP-47 instructs clients to always prefer NIP-44.)
    public var negotiatedEncryption: WalletConnectEncryption {
        encryptions.contains(.nip44) ? .nip44 : .nip04
    }

    /// Whether the wallet advertises support for `method`.
    public func supports(_ method: WalletConnectMethod) -> Bool {
        methods.contains(method)
    }

    /// Maps the tokens of an `encryption` tag to schemes, accepting `"nip44"` as an alias for
    /// `"nip44_v2"` and ignoring tokens it does not recognize.
    private static func parseEncryptions(_ value: String) -> [WalletConnectEncryption] {
        value.split(whereSeparator: \.isWhitespace).compactMap { token in
            switch token {
            case "nip44_v2", "nip44": return .nip44
            case "nip04": return .nip04
            default: return nil
            }
        }
    }
}
