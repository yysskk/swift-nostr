import Foundation

/// Remembers which events each subscription has already delivered, so the copies of one event
/// arriving from several relays collapse into a single delivery.
///
/// Deduplication is scoped per subscription: an event matching two subscriptions is recorded
/// once for each, so both deliver it, and ``removeSubscription(_:)`` forgets a subscription's
/// history when it ends.
///
/// Storage is bounded as entries are recorded, never only when swept, so the cache holds at
/// most ``maxSize`` entries however many subscriptions are open. Both eviction and
/// ``removeExpired(now:)`` take the oldest entries first; dropping one only risks delivering a
/// duplicate later, never losing an event.
struct EventDeduplicationCache {
    /// The maximum number of entries kept across every subscription.
    let maxSize: Int

    /// How long an entry survives after it is recorded.
    let ttl: TimeInterval

    /// One recorded delivery.
    private struct Entry {
        let subscriptionId: String
        let eventId: String
        let recordedAt: Date
    }

    /// The event IDs each subscription has seen: the membership test on the hot path, and what
    /// lets a whole subscription be forgotten at once.
    private var seenEventIds: [String: Set<String>] = [:]

    /// Every entry in the order it was recorded, oldest first, so eviction and expiry take from
    /// the front rather than searching for the oldest.
    private var entries: [Entry] = []

    /// The position of the oldest entry in `entries`. Taking from the front advances this
    /// instead of shifting every element; the entries it leaves behind are dropped in
    /// ``compact()``.
    private var oldestIndex = 0

    /// Creates a cache holding at most `maxSize` entries, each surviving `ttl` seconds.
    /// A `maxSize` below 1 is clamped to 0, which turns deduplication off.
    init(maxSize: Int, ttl: TimeInterval) {
        self.maxSize = max(0, maxSize)
        self.ttl = ttl
    }

    /// The number of entries held, across every subscription.
    var count: Int {
        entries.count - oldestIndex
    }

    /// The number of entries held for `subscriptionId`.
    func count(forSubscription subscriptionId: String) -> Int {
        seenEventIds[subscriptionId]?.count ?? 0
    }

    /// Records that `subscriptionId` has seen `eventId`, returning whether it is new to that
    /// subscription — that is, whether this copy should be delivered.
    ///
    /// Recording beyond ``maxSize`` evicts as many of the oldest entries as it takes to stay
    /// within the limit, so the bound holds on return.
    mutating func record(eventId: String, subscriptionId: String, now: Date = Date()) -> Bool {
        guard seenEventIds[subscriptionId]?.contains(eventId) != true else { return false }
        seenEventIds[subscriptionId, default: []].insert(eventId)
        entries.append(Entry(subscriptionId: subscriptionId, eventId: eventId, recordedAt: now))
        while count > maxSize {
            removeOldest()
        }
        return true
    }

    /// Forgets everything `subscriptionId` has seen, so an event recorded for it again is new.
    mutating func removeSubscription(_ subscriptionId: String) {
        guard seenEventIds.removeValue(forKey: subscriptionId) != nil else { return }
        entries = entries[oldestIndex...].filter { $0.subscriptionId != subscriptionId }
        oldestIndex = 0
    }

    /// Removes every entry recorded more than ``ttl`` before `now`.
    mutating func removeExpired(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-ttl)
        while oldestIndex < entries.count, entries[oldestIndex].recordedAt <= cutoff {
            removeOldest()
        }
    }

    /// Forgets every subscription's history.
    mutating func removeAll() {
        seenEventIds.removeAll()
        entries.removeAll()
        oldestIndex = 0
    }

    /// Removes the oldest entry, which is the one both eviction and expiry take.
    private mutating func removeOldest() {
        let oldest = entries[oldestIndex]
        oldestIndex += 1
        seenEventIds[oldest.subscriptionId]?.remove(oldest.eventId)
        if seenEventIds[oldest.subscriptionId]?.isEmpty == true {
            seenEventIds.removeValue(forKey: oldest.subscriptionId)
        }
        compact()
    }

    /// Drops the entries already taken from the front, once they outnumber the ones left.
    /// Removing from the front stays O(1) amortized this way, instead of shifting every
    /// remaining element on each removal.
    private mutating func compact() {
        guard oldestIndex > entries.count / 2 else { return }
        entries.removeFirst(oldestIndex)
        oldestIndex = 0
    }
}
