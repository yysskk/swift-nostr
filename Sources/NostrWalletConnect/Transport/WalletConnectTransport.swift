public import NostrClient
public import NostrCore

/// The relay transport a ``WalletConnection`` uses to talk to a wallet service.
///
/// This is the module's own seam over relay I/O. The default implementation,
/// ``RelayConnectionTransport``, drives `NostrClient`'s `RelayConnection`; tests substitute an
/// in-memory fake. Keeping the seam here lets the wallet connection be exercised without a live
/// relay and without widening `NostrClient`'s API.
///
/// NIP-47 request events are ephemeral, so ``send(_:)`` is fire-and-forget — the matching response
/// event delivered through ``events()`` is the completion signal, not a relay `OK`.
public protocol WalletConnectTransport: Sendable {
    /// Establishes the underlying relay connection(s).
    func connect() async throws

    /// Opens a subscription for `filters` under `id`.
    func subscribe(id: String, filters: [Filter]) async throws

    /// Closes the subscription with `id`.
    func unsubscribe(id: String) async

    /// Publishes `event` to the relay(s) without waiting for an acknowledgment.
    func send(_ event: Event) async throws

    /// A stream of every event received from the relay(s).
    func events() async -> AsyncStream<Event>

    /// Tears down the connection(s) and ends the ``events()`` stream.
    func disconnect() async
}
