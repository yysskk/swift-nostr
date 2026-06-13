import Foundation

/// An in-memory cache of NIP-01 replaceable events: the newest value per key wins.
///
/// Models replaceable-event semantics — when relays return stale copies of an
/// author's replaceable event, the highest `createdAt` is kept and older copies
/// are ignored. Used by the per-pubkey relay-list stores, keyed by author pubkey.
///
/// This is a plain value type; callers provide isolation (the relay-list stores
/// own it inside an actor).
struct ReplaceableCache<Value> {
    private var entries: [String: (value: Value, createdAt: Int64)] = [:]

    /// Stores `value` for `key` if it is newer than the cached one. An equal
    /// `createdAt` keeps the existing entry.
    /// - Returns: The effective (possibly pre-existing) value.
    @discardableResult
    mutating func store(_ value: Value, createdAt: Int64, for key: String) -> Value {
        if let existing = entries[key], existing.createdAt >= createdAt {
            return existing.value
        }
        entries[key] = (value, createdAt)
        return value
    }

    /// Returns the cached value for `key`, if any.
    func value(for key: String) -> Value? {
        entries[key]?.value
    }
}
