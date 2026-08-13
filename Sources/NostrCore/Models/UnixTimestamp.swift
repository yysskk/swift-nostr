import Foundation

/// Conversions between a Nostr Unix timestamp and `Date` that survive a hostile value.
///
/// A timestamp arrives as a decimal string from a relay, and the full `Int64` range does not
/// round-trip through `Date`: it stores a `Double`, and converting one back with `Int64(_:)` traps
/// when the value is not representable. `Int64.max` seconds rounds *up* past `Int64.max` on the way
/// in, so parsing it and re-emitting it — reading an article, editing it, republishing — killed the
/// process. These clamp instead, so a nonsense timestamp stays nonsense rather than becoming a
/// crash.
package enum UnixTimestamp {
    /// The widest range that converts to `Date` and back without trapping.
    ///
    /// `Double` cannot represent every `Int64` near its bounds, so the limits are pulled in to the
    /// largest magnitudes that survive the round trip exactly.
    package static let representableSeconds: ClosedRange<Int64> = -(1 << 53)...(1 << 53)

    /// A `Date` for `seconds`, clamped to what can be converted back.
    package static func date(fromSeconds seconds: Int64) -> Date {
        let clamped = min(max(seconds, representableSeconds.lowerBound), representableSeconds.upperBound)
        return Date(timeIntervalSince1970: TimeInterval(clamped))
    }

    /// The whole seconds in `date`, clamped to what a Nostr timestamp can carry.
    ///
    /// A `Date` can hold values far outside the representable range — including infinity and NaN
    /// from arithmetic — and `Int64(_:)` traps on all of them.
    package static func seconds(from date: Date) -> Int64 {
        let interval = date.timeIntervalSince1970
        guard interval.isFinite else {
            return interval > 0 ? representableSeconds.upperBound : representableSeconds.lowerBound
        }
        if interval >= Double(representableSeconds.upperBound) { return representableSeconds.upperBound }
        if interval <= Double(representableSeconds.lowerBound) { return representableSeconds.lowerBound }
        return Int64(interval)
    }
}
