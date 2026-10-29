import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("Value Hashable Tests")
struct ValueHashableTests {
    private static let relayA = RelayURL("wss://a.example.com")!
    private static let relayB = RelayURL("wss://b.example.com")!

    private static func event(_ label: String) -> Event {
        Event(
            id: .fixture(label),
            publicKey: .fixture("author"),
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: [],
            content: label,
            signature: .fixture())
    }

    private static func result(_ status: PublishRelayStatus) -> PublishResult {
        PublishResult(statuses: [relayA: status])
    }

    private static func giftWrapped(_ label: String) -> GiftWrappedMessage {
        GiftWrappedMessage(rumor: event(label), recipientGiftWrap: event("recipient"), selfGiftWrap: event("self"))
    }

    static let samples: [HashableSample] = [
        HashableSample(
            "PublishRelayStatus", PublishRelayStatus.failed(.timedOut), PublishRelayStatus.failed(.timedOut),
            PublishRelayStatus.failed(.notConnected)),
        HashableSample("PublishResult", result(.accepted), result(.accepted), result(.pending)),
        HashableSample(
            "PublishedEvent", PublishedEvent(event: event("a"), result: result(.accepted)),
            PublishedEvent(event: event("a"), result: result(.accepted)),
            PublishedEvent(event: event("a"), result: result(.failed(.timedOut)))),
        HashableSample("GiftWrappedMessage", giftWrapped("a"), giftWrapped("a"), giftWrapped("b")),
        HashableSample(
            "SendDirectMessageResult",
            SendDirectMessageResult(
                message: giftWrapped("a"), recipientPublishResult: result(.accepted), selfCopyPublishResult: nil),
            SendDirectMessageResult(
                message: giftWrapped("a"), recipientPublishResult: result(.accepted), selfCopyPublishResult: nil),
            SendDirectMessageResult(
                message: giftWrapped("a"), recipientPublishResult: result(.accepted),
                selfCopyPublishResult: result(.accepted))),
        HashableSample(
            "GiftWrap.UnwrappedMessage",
            GiftWrap.UnwrappedMessage(senderPublicKey: .fixture("alice"), event: event("a")),
            GiftWrap.UnwrappedMessage(senderPublicKey: .fixture("alice"), event: event("a")),
            GiftWrap.UnwrappedMessage(senderPublicKey: .fixture("bob"), event: event("a"))),
        HashableSample(
            "SubscriptionEvent", SubscriptionEvent.eose(relayURL: relayA), SubscriptionEvent.eose(relayURL: relayA),
            SubscriptionEvent.eose(relayURL: relayB)),
        HashableSample(
            "UserMetadata", UserMetadata(name: "alice"), UserMetadata(name: "alice"),
            UserMetadata(name: "alice", about: "hi")),
        HashableSample(
            "PublishStrategy", PublishStrategy.quorum(2), PublishStrategy.quorum(2), PublishStrategy.quorum(3)),
        HashableSample(
            "RelayPoolConfig", RelayPoolConfig(), RelayPoolConfig(), RelayPoolConfig(deduplication: nil)),
        HashableSample(
            "NostrClient.Config", NostrClient.Config(), NostrClient.Config(),
            NostrClient.Config(maximumGossipRelaysPerResolve: 2)),
    ]

    @Test("equal values are equal, hash alike, and collapse in a Set", arguments: samples)
    func hashable(sample: HashableSample) {
        #expect(sample.equalValuesAreEqual)
        #expect(sample.equalValuesHashAlike)
        #expect(sample.differentValueIsUnequal)
        #expect(sample.setCount == 2)
    }
}
