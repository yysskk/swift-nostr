import Foundation

// MARK: - Message Receiving
extension RelayConnection {
    /// Starts the receive loop for the socket identified by `generation`.
    ///
    /// The loop is stored so teardown can cancel it, and it stops as soon as its socket is no
    /// longer the installed one — a loop that outlived its session must not report that session's
    /// death as the current one's.
    func startReceiving(generation: UInt64) {
        receiveTask?.cancel()
        receiveTask = Task {
            while state == .connected, isCurrentSocket(generation) {
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
                                // Guarded exactly as `setAuthenticationResponder` guards its own
                                // call: a relay that re-challenges an already-authenticated or
                                // mid-answer session would otherwise start an overlapping answer
                                // for every frame it sends.
                                if let responder = authenticationResponder, shouldAnswerChallenge {
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
                                // A relay lacking NIP-45 often answers a COUNT with CLOSED;
                                // fail the waiter fast rather than let it time out.
                                if let waiter = pendingCountWaiters.removeValue(forKey: subscriptionId) {
                                    waiter.finish(throwing: NostrError.relayError(message))
                                }
                            case .count(let subscriptionId, let count, let approximate):
                                if let waiter = pendingCountWaiters.removeValue(forKey: subscriptionId) {
                                    waiter.yield(EventCount(value: count, isApproximate: approximate ?? false))
                                    waiter.finish()
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
                    // A socket that has already been replaced or discarded fails on its own time,
                    // often long after the fact. Tearing down here would cancel the live session's
                    // keepalive and fail a connection that is working.
                    guard isCurrentSocket(generation) else { break }

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

            // Streams survive an in-flight auto-reconnect and resume on the
            // new session; otherwise this exit is terminal for them. After an
            // explicit disconnect() this is a no-op — disconnect already
            // finished them. A loop whose socket was superseded leaves the
            // streams to the session that replaced it.
            if !isReconnecting, isCurrentSocket(generation) {
                finishMessageStreams()
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
