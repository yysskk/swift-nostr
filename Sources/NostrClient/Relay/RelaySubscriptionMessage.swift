import Foundation
import NostrCore

struct RelaySubscriptionMessage: Sendable {
    let relayURL: URL
    let message: RelayMessage
}
