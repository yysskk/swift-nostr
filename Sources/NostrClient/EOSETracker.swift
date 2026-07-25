import Foundation

/// Tracks which relays have sent EOSE for a one-time fetch.
///
/// `expectedRelays` is nil until the subscribed relay set is known; an empty
/// set is vacuously complete (nothing was subscribed, so nothing is pending).
struct EOSETracker: Sendable {
    private(set) var expectedRelays: Set<URL>?
    private(set) var receivedRelays: Set<URL> = []

    var isComplete: Bool {
        guard let expectedRelays else { return false }
        return expectedRelays.isSubset(of: receivedRelays)
    }

    @discardableResult
    mutating func setExpectedRelays(_ relays: Set<URL>) -> Bool {
        expectedRelays = relays
        return isComplete
    }

    @discardableResult
    mutating func recordEOSE(from relayURL: URL) -> Bool {
        receivedRelays.insert(relayURL)
        return isComplete
    }
}
