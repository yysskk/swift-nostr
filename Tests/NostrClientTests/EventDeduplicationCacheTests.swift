import Foundation
import Testing

@testable import NostrClient

@Suite("Event Deduplication Cache Tests")
struct EventDeduplicationCacheTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeCache(maxSize: Int = 10, ttl: TimeInterval = 300) -> EventDeduplicationCache {
        EventDeduplicationCache(maxSize: maxSize, ttl: ttl)
    }

    // MARK: - Per-subscription scope

    @Test("an event is new to a subscription only the first time")
    func anEventIsNewOnlyOnce() {
        var cache = makeCache()

        let first = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        let repeated = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        #expect(first)
        #expect(!repeated)
        #expect(cache.count == 1)
    }

    @Test("an event is new to each subscription separately")
    func anEventIsNewToEachSubscription() {
        var cache = makeCache()

        let toFirst = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        let toSecond = cache.record(eventId: "event", subscriptionId: "sub_2", now: now)

        #expect(toFirst)
        #expect(toSecond)
        #expect(cache.count == 2)
        #expect(cache.count(forSubscription: "sub_1") == 1)
        #expect(cache.count(forSubscription: "sub_2") == 1)
    }

    @Test("removing a subscription forgets only its own history")
    func removingASubscriptionForgetsOnlyItsOwnHistory() {
        var cache = makeCache()
        _ = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        _ = cache.record(eventId: "event", subscriptionId: "sub_2", now: now)

        cache.removeSubscription("sub_1")
        // Forgotten, so the same event is new again to the removed subscription, while the
        // one left alone still remembers it.
        let newToRemoved = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        let newToKept = cache.record(eventId: "event", subscriptionId: "sub_2", now: now)

        #expect(newToRemoved)
        #expect(!newToKept)
        #expect(cache.count(forSubscription: "sub_1") == 1)
        #expect(cache.count(forSubscription: "sub_2") == 1)
    }

    @Test("removing an unknown subscription changes nothing")
    func removingAnUnknownSubscriptionChangesNothing() {
        var cache = makeCache()
        _ = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        cache.removeSubscription("sub_2")

        #expect(cache.count == 1)
        #expect(cache.count(forSubscription: "sub_1") == 1)
    }

    @Test("removeAll forgets every subscription")
    func removeAllForgetsEverySubscription() {
        var cache = makeCache()
        _ = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        _ = cache.record(eventId: "event", subscriptionId: "sub_2", now: now)

        cache.removeAll()
        let isNewAgain = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        #expect(isNewAgain)
        #expect(cache.count == 1)
        #expect(cache.count(forSubscription: "sub_2") == 0)
    }

    // MARK: - Size limit

    @Test("recording past the limit evicts the oldest entry immediately")
    func recordingPastTheLimitEvictsTheOldestEntry() {
        var cache = makeCache(maxSize: 1)

        _ = cache.record(eventId: "older", subscriptionId: "sub_1", now: now)
        _ = cache.record(eventId: "newer", subscriptionId: "sub_2", now: now.addingTimeInterval(1))

        // The bound holds on return from `record`, with no sweep in between.
        #expect(cache.count == 1)
        #expect(cache.count(forSubscription: "sub_1") == 0)
        #expect(cache.count(forSubscription: "sub_2") == 1)

        // The evicted entry is genuinely forgotten, so its event is new again — and taking it
        // back in evicts the entry that displaced it.
        let evictedIsNewAgain = cache.record(
            eventId: "older", subscriptionId: "sub_1", now: now.addingTimeInterval(2))
        #expect(evictedIsNewAgain)
        #expect(cache.count == 1)
        #expect(cache.count(forSubscription: "sub_2") == 0)
    }

    @Test("the count never exceeds the limit over many recordings")
    func theCountNeverExceedsTheLimitOverManyRecordings() {
        var cache = makeCache(maxSize: 10)

        for index in 0..<100 {
            let isNew = cache.record(
                eventId: "event_\(index)",
                subscriptionId: "sub_\(index % 4)",
                now: now.addingTimeInterval(TimeInterval(index))
            )
            #expect(isNew)
            #expect(cache.count == min(index + 1, 10))
        }

        // Only the ten most recent events are still remembered.
        let lastIsRemembered = cache.record(eventId: "event_99", subscriptionId: "sub_3", now: now)
        let evictedIsForgotten = cache.record(eventId: "event_89", subscriptionId: "sub_1", now: now)
        #expect(!lastIsRemembered)
        #expect(evictedIsForgotten)
    }

    @Test("a maximum size of zero turns deduplication off")
    func aMaximumSizeOfZeroTurnsDeduplicationOff() {
        var cache = makeCache(maxSize: 0)

        let first = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)
        let repeated = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        // Nothing is remembered, so every copy is treated as new.
        #expect(first)
        #expect(repeated)
        #expect(cache.count == 0)
    }

    @Test("a negative maximum size is clamped to zero")
    func aNegativeMaximumSizeIsClampedToZero() {
        let cache = makeCache(maxSize: -1)

        #expect(cache.maxSize == 0)
    }

    // MARK: - Expiry

    @Test("expiry removes entries past the TTL and keeps newer ones")
    func expiryRemovesEntriesPastTheTTL() {
        var cache = makeCache(ttl: 300)
        _ = cache.record(eventId: "older", subscriptionId: "sub_1", now: now)
        _ = cache.record(eventId: "newer", subscriptionId: "sub_1", now: now.addingTimeInterval(200))

        cache.removeExpired(now: now.addingTimeInterval(301))
        let expiredIsNewAgain = cache.record(
            eventId: "older", subscriptionId: "sub_1", now: now.addingTimeInterval(301))
        let survivorIsRemembered = cache.record(
            eventId: "newer", subscriptionId: "sub_1", now: now.addingTimeInterval(301))

        #expect(expiredIsNewAgain)
        #expect(!survivorIsRemembered)
    }

    @Test("expiry inside the TTL keeps every entry")
    func expiryInsideTheTTLKeepsEveryEntry() {
        var cache = makeCache(ttl: 300)
        _ = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        cache.removeExpired(now: now.addingTimeInterval(299))

        #expect(cache.count == 1)
        #expect(cache.count(forSubscription: "sub_1") == 1)
    }

    @Test("expiry drops a subscription once its last entry expires")
    func expiryDropsASubscriptionOnceItsLastEntryExpires() {
        var cache = makeCache(ttl: 300)
        _ = cache.record(eventId: "event", subscriptionId: "sub_1", now: now)

        cache.removeExpired(now: now.addingTimeInterval(301))

        #expect(cache.count == 0)
        #expect(cache.count(forSubscription: "sub_1") == 0)
    }

    @Test("expiry on an empty cache is a no-op")
    func expiryOnAnEmptyCacheIsANoOp() {
        var cache = makeCache()

        cache.removeExpired(now: now)

        #expect(cache.count == 0)
    }
}
