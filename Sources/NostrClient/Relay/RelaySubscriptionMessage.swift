import Foundation
import NostrCore

struct RelaySubscriptionMessage: Sendable {
    let relayURL: RelayURL
    let message: RelayMessage
}
