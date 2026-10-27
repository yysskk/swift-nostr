/// A session's seam over relay I/O.
///
/// A NIP-46 remote-signer session (`NostrConnect`'s `RemoteSigner`) or a NIP-47 wallet connection
/// (`NostrWalletConnect`'s `WalletConnection`) talks to this instead of touching relays directly:
/// the default ``RelayConnectionTransport`` drives ``RelayConnection``s in production, and tests
/// substitute an in-memory fake so a session can be exercised without a live relay.
///
/// Both protocols' request events are ephemeral, so ``send(_:)`` is fire-and-forget — the matching
/// response event delivered through ``events()`` is the completion signal, not a relay `OK`.
///
/// https://github.com/nostr-protocol/nips/blob/master/46.md
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public protocol RelayTransport: Sendable {
    /// Establishes the underlying relay connection(s).
    /// - Throws: ``RelayConnection/Error`` when no relay can be connected.
    func connect() async throws(RelayConnection.Error)

    /// Opens a subscription for `filters` under `id`.
    /// - Throws: ``RelayConnection/Error`` when no relay accepts the subscription.
    func subscribe(id: String, filters: [Filter]) async throws(RelayConnection.Error)

    /// Closes the subscription with `id`.
    func unsubscribe(id: String) async

    /// Publishes `event` to the relay(s) without waiting for an acknowledgment.
    /// - Throws: ``RelayConnection/Error`` when no relay accepts the event.
    func send(_ event: Event) async throws(RelayConnection.Error)

    /// A stream of every event received from the relay(s).
    func events() async -> AsyncStream<Event>

    /// Tears down the connection(s) and ends the ``events()`` stream.
    func disconnect() async
}
