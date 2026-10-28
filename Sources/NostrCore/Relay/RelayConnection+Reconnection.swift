import Foundation

/// Draws the random factor a reconnect delay is scaled by, given the range to draw from.
///
/// Exists so the backoff can be tested for its bounds rather than for a particular random draw.
typealias ReconnectJitter = @Sendable (ClosedRange<Double>) -> Double

// MARK: - Reconnection
extension RelayConnection {
    /// How much of a reconnect delay is randomized.
    ///
    /// Every relay behind one flaky uplink fails at the same moment and would otherwise retry in
    /// lockstep at 1 s, 2 s, 4 s… — a thundering herd that arrives together and fails together.
    /// Scaling by half to one keeps the backoff's shape while spreading the attempts out.
    private static let jitterRange: ClosedRange<Double> = 0.5...1.0

    /// Resets reconnect state after successful connection
    func resetReconnectState() {
        reconnectAttempts = 0
        currentReconnectDelay = config.firstReconnectDelay
        isReconnecting = false
    }

    /// Schedules a reconnection attempt if ``RelayConnectionConfig/reconnect`` allows another.
    func scheduleReconnectIfNeeded() {
        guard let policy = config.reconnect else {
            // Equally terminal: nothing will reconnect, so the drop that brought us here ends the
            // message streams. The receive loop cannot be relied on to do it — a drop that goes
            // through `discardSocket()` retires the loop's generation first, so the loop exits
            // knowing it no longer speaks for the connection.
            finishMessageStreams()
            return
        }
        guard !isReconnecting else { return }

        guard policy.allowsAttempt(after: reconnectAttempts) else {
            // Terminal give-up: the receive loop kept the message streams
            // alive for this reconnect cycle, and no further attempt will be
            // scheduled, so nothing else can end them.
            finishMessageStreams()
            return
        }

        isReconnecting = true

        // A previous task can still be alive here if `isReconnecting` was cleared by a concurrent
        // path; overwriting the slot would leave it running and racing this one.
        reconnectTask?.cancel()

        reconnectTask = Task {
            // Wait with exponential backoff. The delay is bounded where it is read, not where it
            // was configured: the fields are mutable, so a zero or negative delay set after init
            // would otherwise turn the unlimited-attempt default into a loop with no pause at all.
            let delay = policy.boundedDelay(currentReconnectDelay)
            try? await Task.sleep(for: delay * jitter(Self.jitterRange))

            guard !Task.isCancelled else { return }

            // Calculate next delay with exponential backoff
            currentReconnectDelay = policy.nextDelay(after: delay)
            reconnectAttempts += 1

            do {
                try await connect()
                // Resubscribe to all active subscriptions after reconnection
                await resubscribeAll()
            } catch {
                // Connection failed, schedule another attempt
                isReconnecting = false
                scheduleReconnectIfNeeded()
            }
        }
    }

    /// Resubscribes to all active subscriptions after reconnection
    private func resubscribeAll() async {
        let currentSubscriptions = subscriptions
        for (subscriptionID, filters) in currentSubscriptions {
            do {
                try await subscribe(id: subscriptionID, filters: filters)
            } catch {
                // Continue with other subscriptions even if one fails
            }
        }
    }

    /// Manually trigger a reconnection attempt.
    ///
    /// Goes through ``RelayConnection/disconnect()``, so existing
    /// ``RelayConnection/messages()`` streams finish — obtain a new stream
    /// after reconnecting.
    ///
    /// - Throws: Everything ``RelayConnection/connect()`` throws.
    public func reconnect() async throws(Error) {
        disconnect()
        resetReconnectState()
        try await connect()
    }
}
