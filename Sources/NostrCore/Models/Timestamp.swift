import Foundation

/// A Nostr timestamp: whole seconds since the Unix epoch, the unit NIP-01 uses for `created_at`
/// and filters' `since` and `until`.
///
/// ``rawValue`` holds the number exactly as it travels on the wire, so decoding and re-encoding an
/// event never changes its timestamp — or its id, which hashes it. The value encodes to and from
/// JSON as a bare integer.
///
/// Converting to and from `Date` never traps. The full `Int64` range does not round-trip through
/// `Date`: it stores a `Double`, and converting one back with `Int64(_:)` traps when the value is
/// not representable. `Int64.max` seconds rounds *up* past `Int64.max` on the way in, so parsing
/// such a timestamp and re-emitting it — reading an article, editing it, republishing — would kill
/// the process, and a `Date` produced by arithmetic can be infinite or NaN. ``init(_:)`` and
/// ``date`` clamp to the range that converts exactly instead, so a nonsense timestamp stays
/// nonsense rather than becoming a crash.
public struct Timestamp: RawRepresentable, Sendable, Hashable {
    /// The widest range of seconds that converts to `Date` and back without trapping.
    ///
    /// `Double` cannot represent every `Int64` near its bounds, so the limits are pulled in to the
    /// largest magnitudes that survive the round trip exactly.
    static let representableSeconds: ClosedRange<Int64> = -(1 << 53)...(1 << 53)

    /// The number of seconds since the Unix epoch, exactly as on the wire.
    public let rawValue: Int64

    /// Creates a timestamp from a number of seconds since the Unix epoch.
    ///
    /// Any value is kept as is, including one outside the range ``date`` can express.
    /// - Parameter rawValue: The seconds since the Unix epoch.
    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Creates a timestamp from the whole seconds in `date`.
    ///
    /// Sub-second precision is truncated toward zero. A date beyond ±2^53 seconds from the epoch
    /// — including an infinite one — is clamped to that bound, and NaN becomes the lower bound.
    /// - Parameter date: The moment to represent.
    public init(_ date: Date) {
        let interval = date.timeIntervalSince1970
        let bounds = Self.representableSeconds
        if interval.isNaN {
            self.rawValue = bounds.lowerBound
        } else if interval >= Double(bounds.upperBound) {
            self.rawValue = bounds.upperBound
        } else if interval <= Double(bounds.lowerBound) {
            self.rawValue = bounds.lowerBound
        } else {
            self.rawValue = Int64(interval)
        }
    }

    /// The current time, in whole seconds.
    public static var now: Timestamp {
        Timestamp(Date())
    }

    /// The timestamp as a `Date`.
    ///
    /// A ``rawValue`` beyond ±2^53 seconds from the epoch is clamped to that bound, so the
    /// conversion never traps and the result converts back with ``init(_:)``.
    public var date: Date {
        let bounds = Self.representableSeconds
        let clamped = min(max(rawValue, bounds.lowerBound), bounds.upperBound)
        return Date(timeIntervalSince1970: TimeInterval(clamped))
    }
}

extension Timestamp: Comparable {
    /// Orders timestamps chronologically.
    public static func < (lhs: Timestamp, rhs: Timestamp) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension Timestamp: CustomStringConvertible {
    /// The seconds since the Unix epoch in decimal, the form tag values such as NIP-40
    /// `expiration` carry.
    public var description: String {
        String(rawValue)
    }
}

extension Timestamp: Codable {
    /// Decodes a timestamp from an integer number of seconds.
    /// - Throws: `DecodingError` if the value is not an integer that fits in `Int64`.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int64.self))
    }

    /// Encodes the timestamp as its integer number of seconds.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
