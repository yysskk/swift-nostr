public import NostrCore

extension Event.Kind {
    /// NIP-47 wallet info event (kind 13194), published by the wallet service to advertise its
    /// supported methods, encryption schemes, and notification types.
    public static let walletConnectInfo = Event.Kind(rawValue: 13194)

    /// NIP-47 wallet request event (kind 23194), sent by the client to the wallet service. Its
    /// content is an encrypted JSON-RPC request.
    public static let walletConnectRequest = Event.Kind(rawValue: 23194)

    /// NIP-47 wallet response event (kind 23195), returned by the wallet service. Its content is an
    /// encrypted JSON-RPC response.
    public static let walletConnectResponse = Event.Kind(rawValue: 23195)

    /// NIP-47 wallet notification event encrypted with NIP-04 (kind 23196).
    public static let walletConnectNotificationLegacy = Event.Kind(rawValue: 23196)

    /// NIP-47 wallet notification event encrypted with NIP-44 (kind 23197).
    public static let walletConnectNotification = Event.Kind(rawValue: 23197)
}
