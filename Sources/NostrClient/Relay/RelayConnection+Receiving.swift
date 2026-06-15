import Foundation
import NostrCore

// MARK: - Message Receiving
extension RelayConnection {
    func startReceiving() {
        Task {
            while state == .connected {
                do {
                    guard let task = webSocketTask else { break }

                    // Wait indefinitely: liveness is detected by the keepalive ping,
                    // not by how often the relay has messages to deliver.
                    let message = try await task.receive()

                    switch message {
                    case .string(let text):
                        if let relayMessage = try? RelayMessage.parse(text) {
                            switch relayMessage {
                            case .ok(let eventId, let accepted, let message):
                                // Settle a pending NIP-42 authentication for this event id.
                                if let pubkey = pendingAuthentications.removeValue(forKey: eventId) {
                                    settleAuthentication(
                                        pubkey: pubkey, accepted: accepted, message: message)
                                }
                                for waiter in removeAllPublishWaiters(eventId: eventId) {
                                    if accepted {
                                        waiter.finish()
                                    } else {
                                        waiter.finish(
                                            throwing: EventRejection(eventId: eventId, message: message))
                                    }
                                }
                            case .auth(let challenge):
                                authenticationChallenge = challenge
                                if let responder = authenticationResponder {
                                    respondToChallenge(challenge, with: responder)
                                }
                            case .closed(let subscriptionId, let message):
                                // A subscription the relay closed pending authentication is
                                // re-requested once an AUTH round-trip succeeds (NIP-42).
                                if RelayResponsePrefix(message: message) == .authRequired,
                                    subscriptions[subscriptionId] != nil
                                {
                                    subscriptionsAwaitingAuthentication.insert(subscriptionId)
                                }
                            default:
                                break
                            }
                            yieldToMessageContinuations(relayMessage)
                        }

                    case .data:
                        // Binary data not expected from Nostr relays
                        break
                    }
                } catch {
                    // The keepalive has no work to do once the receive loop is gone.
                    keepaliveTask?.cancel()
                    keepaliveTask = nil
                    if state == .connected {
                        updateState(.failed(error.localizedDescription))
                        scheduleReconnectIfNeeded()
                    }
                    break
                }
            }

            // Don't finish continuations if we're reconnecting
            if !isReconnecting {
                for continuation in messageContinuations.values {
                    continuation.finish()
                }
                messageContinuations.removeAll()
            }
        }
    }

    /// Yields the relay message to all active message continuations (actor-isolated).
    private func yieldToMessageContinuations(_ message: RelayMessage) {
        for continuation in messageContinuations.values {
            continuation.yield(message)
        }
    }
}
