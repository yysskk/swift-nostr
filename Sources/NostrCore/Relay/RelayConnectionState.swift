import Foundation

/// Represents the connection state of a relay
public enum RelayConnectionState: Sendable, Hashable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(String)
}
