import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrMessagesAPI`` that implements only the ``NostrMessaging`` primitives: it
/// records every call, gift-wraps each send for real without publishing it (reporting it accepted
/// by ``relayURL``), opens gift wraps with a
/// ``DirectMessageParser`` bound to its signer, and answers each subscription with a finished
/// sequence of canned gift wraps, so the protocol extension can be exercised without a relay pool.
actor RecordingMessagingCapabilities: NostrMessaging {
    struct Send: Sendable {
        let template: EventTemplate
        let recipientPublicKey: PublicKey
        let expiration: Timestamp?
        let strategy: PublishStrategy?
    }

    /// The identity sends are authored under and gift wraps are opened as.
    let signer: EventSigner
    /// The relay every canned subscription reports as having accepted it.
    let relayURL: RelayURL
    /// What every subscription yields before it finishes.
    let cannedGiftWraps: [Event]

    private(set) var sends: [Send] = []
    private(set) var subscribeLimits: [Int] = []

    init(signer: EventSigner, relayURL: RelayURL, cannedGiftWraps: [Event] = []) {
        self.signer = signer
        self.relayURL = relayURL
        self.cannedGiftWraps = cannedGiftWraps
    }

    // MARK: - NostrMessaging

    func sendGiftWrapped(
        _ template: EventTemplate,
        to recipientPublicKey: PublicKey,
        expiration: Timestamp?,
        strategy: PublishStrategy?
    ) async throws -> SendDirectMessageResult {
        sends.append(
            Send(
                template: template, recipientPublicKey: recipientPublicKey, expiration: expiration, strategy: strategy
            ))
        let rumor = UnsignedEvent(template, publicKey: signer.publicKey).asRumor()
        let message = GiftWrappedMessage(
            rumor: rumor,
            recipientGiftWrap: try await GiftWrap.wrap(
                template, signer: signer, to: recipientPublicKey, expiration: expiration),
            selfGiftWrap: try await GiftWrap.wrap(
                template, signer: signer, to: signer.publicKey, expiration: expiration)
        )
        return SendDirectMessageResult(
            message: message,
            recipientPublishResult: PublishResult(statuses: [relayURL: .accepted]),
            selfCopyPublishResult: PublishResult(statuses: [relayURL: .accepted])
        )
    }

    func open(_ giftWrap: Event) async throws -> DirectMessagePayload {
        try await DirectMessageParser(signer: signer).open(giftWrap)
    }

    func subscribe(limit: Int) async throws -> DirectMessagePayloadSequence {
        subscribeLimits.append(limit)
        return DirectMessagePayloadSequence(
            subscription: cannedSubscription(id: SubscriptionID(rawValue: "payloads_\(subscribeLimits.count)")),
            parser: DirectMessageParser(signer: signer)
        )
    }

    // MARK: - Private

    private func cannedSubscription(id: SubscriptionID) -> SubscriptionSequence {
        let (stream, continuation) = AsyncStream.makeStream(of: SubscriptionEvent.self)
        for giftWrap in cannedGiftWraps {
            continuation.yield(.event(relayURL: relayURL, event: giftWrap))
        }
        continuation.yield(.eose(relayURL: relayURL))
        continuation.finish()
        return SubscriptionSequence(id: id, expectedRelays: [relayURL], stream: stream, onClose: {})
    }
}
