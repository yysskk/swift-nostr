import Foundation
import NostrClient
import NostrCore

/// A stand-in for ``NostrMessagesAPI`` that implements only the ``NostrMessaging`` primitives: it
/// records every call, gift-wraps each send for real without publishing it, opens gift wraps with a
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
    private(set) var parsedGiftWraps: [Event] = []
    private(set) var payloadLimits: [Int] = []
    private(set) var giftWrapLimits: [Int] = []

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
        return SendDirectMessageResult(
            rumor: rumor,
            recipientGiftWrap: try await GiftWrap.wrap(
                event: rumor, signer: signer, recipientPublicKey: recipientPublicKey, expiration: expiration),
            selfGiftWrap: try await GiftWrap.wrap(
                event: rumor, signer: signer, recipientPublicKey: signer.publicKey, expiration: expiration)
        )
    }

    func parsePayload(_ giftWrap: Event) async throws -> DirectMessagePayload {
        parsedGiftWraps.append(giftWrap)
        return try await DirectMessageParser(signer: signer).parsePayload(giftWrap)
    }

    func payloads(limit: Int) async throws -> DirectMessagePayloadSequence {
        payloadLimits.append(limit)
        return DirectMessagePayloadSequence(
            subscription: cannedSubscription(id: SubscriptionID(rawValue: "payloads_\(payloadLimits.count)")),
            parser: DirectMessageParser(signer: signer)
        )
    }

    func giftWraps(limit: Int) async throws -> SubscriptionSequence {
        giftWrapLimits.append(limit)
        return cannedSubscription(id: SubscriptionID(rawValue: "gift_wraps_\(giftWrapLimits.count)"))
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
