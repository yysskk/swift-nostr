import Foundation
import NostrCore

/// NIP-17 private direct messages: gift-wrapped sends, reactions, files, rumors of any kind, and
/// the streams that deliver them already unwrapped. Reached as ``NostrClient/messages``.
///
/// Implements the ``NostrMessaging`` primitives over the client's signer and relay pool, and
/// inherits every convenience from the protocol's extension:
/// ``NostrMessaging/send(_:to:subject:replyTo:expiration:strategy:)``,
/// ``NostrMessaging/react(to:reaction:expiration:strategy:)``, and
/// ``NostrMessaging/sendFile(_:to:expiration:strategy:)``
/// gift-wrap a template through ``sendGiftWrapped(_:to:expiration:strategy:)``; ``open(_:)`` unwraps
/// a received gift wrap. ``subscribe(limit:)`` delivers every payload, with
/// ``DirectMessagePayloadSequence/messages`` and ``DirectMessagePayloadSequence/giftWraps`` as views.
///
/// Every send is routed by the addressee's NIP-17 DM relay list (kind 10050) via
/// ``NostrClient/routing``, discovering and caching the list as needed and falling back to the
/// full pool when an addressee has advertised none.
public struct NostrMessagesAPI: NostrMessaging {
    let client: NostrClient

    // MARK: - NostrMessaging

    /// Authors `template` as an unsigned rumor under the configured signer's public key and sends it
    /// gift-wrapped for the recipient plus the sender's self-copy, each routed to its addressee's DM
    /// relays.
    @discardableResult
    public func sendGiftWrapped(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult {
        let message = try await client.withSigner { signer, publicKey in
            try await DirectMessageBuilder(signer: signer).wrapWithSelfCopy(
                template, senderPublicKey: publicKey, to: recipientPublicKey, expiration: expiration)
        }

        return try await deliver(message, to: recipientPublicKey, strategy: strategy)
    }

    /// Unwraps a received gift wrap into the message, reaction, or file message it carries.
    public func open(_ giftWrap: Event) async throws -> DirectMessagePayload {
        try await client.withSigner { signer, _ in
            try await DirectMessageParser(signer: signer).open(giftWrap)
        }
    }

    /// Subscribes to the current user's gift wraps on the whole pool, delivering each readable one
    /// unwrapped.
    public func subscribe(limit: Int) async throws -> DirectMessagePayloadSequence {
        let parser = try await parser()
        let subscription = try await client.pool.subscribe(filters: [try await giftWrapFilter(limit: limit)])
        return DirectMessagePayloadSequence(subscription: subscription, parser: parser)
    }

    // MARK: - Private

    /// Routes a built message's gift wraps to the recipient's and sender's kind-10050 DM relays and
    /// publishes them, returning the message with its per-relay outcomes.
    ///
    /// A nil target means the addressee advertised no DM relay list (or none could be connected), so
    /// the copy falls back to the full pool rather than being dropped; the recipient copy's fallback
    /// throws ``RelayPool/Error/emptyPool`` when the pool is also empty. The recipient and sender
    /// addressees are resolved in parallel — each may trigger an independent relay-list fetch — and
    /// the best-effort self-copy never blocks or fails the primary send.
    private func deliver(
        _ message: GiftWrappedMessage,
        to recipientPublicKey: PublicKey,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult {
        async let recipientTargetsTask = inboxTargets(for: recipientPublicKey)
        // The rumor is authored under the sender's key, so it names the self-copy's addressee.
        async let senderTargetsTask = inboxTargets(for: message.rumor.publicKey)
        let recipientTargets = await recipientTargetsTask
        let senderTargets = await senderTargetsTask

        async let selfCopyDelivery = publishBestEffort(message.selfGiftWrap, toURLs: senderTargets)
        let recipientResult = try await client.pool.publish(
            message.recipientGiftWrap, to: recipientTargets, strategy: strategy
        )
        let selfCopyResult = await selfCopyDelivery

        return SendDirectMessageResult(
            message: message,
            recipientPublishResult: recipientResult,
            selfCopyPublishResult: selfCopyResult
        )
    }

    /// Publishes an event, swallowing failures (used for non-fatal NIP-17 self-copies).
    /// Always uses the pool's default strategy so a caller-supplied strategy
    /// never makes the best-effort publish block the primary send.
    /// - Parameter relayURLs: The canonical relays to target, or nil to broadcast to the full pool.
    /// - Returns: The per-relay outcome, or nil if the publish failed outright.
    private func publishBestEffort(_ event: Event, toURLs relayURLs: Set<RelayURL>?) async -> PublishResult? {
        try? await client.pool.publish(event, to: relayURLs, strategy: nil)
    }

    /// Resolves the kind-10050 DM inbox relays to route a gift wrap to for `publicKey`, connecting
    /// them per the gossip policy.
    /// - Returns: The connected inbox relays, or nil when the addressee advertised no DM relay
    ///   list (or none could be connected) — signalling a fall back to the full relay pool.
    private func inboxTargets(for publicKey: PublicKey) async -> Set<RelayURL>? {
        let connected = await client.routing.connectedInboxRelays(for: publicKey)
        return connected.isEmpty ? nil : connected
    }

    /// Builds the gift-wrap filter for the current user's direct messages.
    private func giftWrapFilter(limit: Int) async throws -> Filter {
        Filter(
            kinds: [.giftWrap],
            publicKeyReferences: [try await client.requiredPublicKey()],
            limit: limit
        )
    }

    /// A parser bound to the active signer, for the sequence that keeps unwrapping payloads as
    /// they arrive. Deliberately lets the signer outlive the call: a live sequence needs it for
    /// the subscription's whole lifetime.
    private func parser() async throws -> DirectMessageParser {
        try await client.withSigner { signer, _ in DirectMessageParser(signer: signer) }
    }
}
