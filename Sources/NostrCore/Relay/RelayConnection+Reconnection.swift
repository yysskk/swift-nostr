import Foundation

// MARK: - Reconnection
extension RelayConnection {
    /// Resets reconnect state after successful connection
    func resetReconnectState() {
        reconnectAttempts = 0
        currentReconnectDelay = config.initialReconnectDelay
        isReconnecting = false
    }

    /// Schedules a reconnection attempt if auto-reconnect is enabled
    func scheduleReconnectIfNeeded() {
        guard config.autoReconnect else { return }
        guard !isReconnecting else { return }

        // Check if we've exceeded max attempts
        if config.maxReconnectAttempts > 0 && reconnectAttempts >= config.maxReconnectAttempts {
            return
        }

        isReconnecting = true

        reconnectTask = Task {
            // Wait with exponential backoff
            let delay = currentReconnectDelay
            try? await Task.sleep(for: .seconds(delay))

            guard !Task.isCancelled else { return }

            // Calculate next delay with exponential backoff
            currentReconnectDelay = min(
                currentReconnectDelay * config.reconnectBackoffMultiplier,
                config.maxReconnectDelay
            )
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
        for (subscriptionId, filters) in currentSubscriptions {
            do {
                try await subscribe(subscriptionId: subscriptionId, filters: filters)
            } catch {
                // Continue with other subscriptions even if one fails
            }
        }
    }

    /// Manually trigger a reconnection attempt
    public func reconnect() async throws {
        disconnect()
        resetReconnectState()
        try await connect()
    }
}
