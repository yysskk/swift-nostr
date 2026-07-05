public import NostrCore

/// The relay transport a ``RemoteSigner`` uses to talk to a remote signer.
///
/// The module's seam over relay I/O; the default ``RelayConnectionTransport`` drives NostrCore
/// `RelayConnection`s and tests substitute an in-memory fake. NIP-46 request events (kind 24133)
/// are ephemeral, so ``send(_:)`` is fire-and-forget — the matching response event delivered
/// through ``events()`` is the completion signal, not a relay `OK`.
/// https://github.com/nostr-protocol/nips/blob/master/46.md
public protocol RemoteSignerTransport: Sendable {
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
