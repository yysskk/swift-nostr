import Foundation
import NostrCore
import Testing

/// A timestamp arrives from a relay as a number or a decimal tag value, and the full `Int64` range
/// does not round-trip through `Date` — it stores a `Double`, and converting one back with
/// `Int64(_:)` traps on a value it cannot represent. Parsing such a value and re-emitting it killed
/// the process.
@Suite("Timestamp Tests")
struct TimestampTests {
    /// The largest magnitude, in seconds, that converts to `Date` and back exactly.
    let bound: Int64 = 1 << 53

    @Test("the raw value is kept exactly", arguments: [Int64.min, -1, 0, 1_700_000_000, Int64.max])
    func rawValueRoundTrips(seconds: Int64) {
        #expect(Timestamp(rawValue: seconds).rawValue == seconds)
    }

    @Test("ordinary timestamps round-trip through Date exactly")
    func ordinaryTimestampsAreExact() {
        for seconds in [Int64(0), 1, 1_700_000_000, -1, -1_700_000_000, 1 << 53, -(1 << 53)] {
            let timestamp = Timestamp(rawValue: seconds)
            #expect(Timestamp(timestamp.date) == timestamp)
        }
    }

    @Test(
        "an out-of-range raw value clamps its date instead of trapping",
        arguments: [Int64.max, Int64.min, Int64.max - 1, 9_223_372_036_854_775_000]
    )
    func extremeSecondsSurviveTheRoundTrip(seconds: Int64) {
        let date = Timestamp(rawValue: seconds).date
        // The trap was here: converting the Date back to seconds.
        let back = Timestamp(date)

        #expect(back.rawValue == (seconds > 0 ? bound : -bound))
    }

    @Test("a date clamps to the representable bounds")
    func datesClampAtTheBounds() {
        #expect(Timestamp(Date(timeIntervalSince1970: TimeInterval(bound))).rawValue == bound)
        #expect(Timestamp(Date(timeIntervalSince1970: TimeInterval(bound) * 2)).rawValue == bound)
        #expect(Timestamp(Date(timeIntervalSince1970: -TimeInterval(bound))).rawValue == -bound)
        #expect(Timestamp(Date(timeIntervalSince1970: -TimeInterval(bound) * 2)).rawValue == -bound)
        #expect(Timestamp(Date(timeIntervalSince1970: 1e300)).rawValue == bound)
    }

    @Test("a non-finite date clamps rather than trapping")
    func nonFiniteDatesClamp() {
        #expect(Timestamp(Date(timeIntervalSince1970: .infinity)).rawValue == bound)
        #expect(Timestamp(Date(timeIntervalSince1970: -.infinity)).rawValue == -bound)
        #expect(Timestamp(Date(timeIntervalSince1970: .nan)).rawValue == -bound)
        // Arithmetic is how a NaN date usually appears.
        let nan = Date(timeIntervalSince1970: .infinity).addingTimeInterval(-.infinity)
        #expect(Timestamp(nan).rawValue == -bound)
    }

    @Test("fractional seconds truncate toward zero")
    func fractionalSecondsTruncate() {
        #expect(Timestamp(Date(timeIntervalSince1970: 1_700_000_000.9)).rawValue == 1_700_000_000)
        #expect(Timestamp(Date(timeIntervalSince1970: 0.5)).rawValue == 0)
        #expect(Timestamp(Date(timeIntervalSince1970: -0.5)).rawValue == 0)
        #expect(Timestamp(Date(timeIntervalSince1970: -1_700_000_000.9)).rawValue == -1_700_000_000)
    }

    @Test("now is the current time in whole seconds")
    func nowIsCurrent() {
        let before = Int64(Date().timeIntervalSince1970)
        let now = Timestamp.now.rawValue
        let after = Int64(Date().timeIntervalSince1970)

        #expect((before...after).contains(now))
    }

    @Test("timestamps order chronologically")
    func timestampsAreComparable() {
        let earlier = Timestamp(rawValue: -5)
        let later = Timestamp(rawValue: 1_700_000_000)

        #expect(earlier < later)
        #expect(!(later < earlier))
        #expect([later, earlier].max() == later)
        #expect(Timestamp(rawValue: 7) == Timestamp(rawValue: 7))
    }

    @Test("the description is the decimal seconds")
    func descriptionIsDecimalSeconds() {
        #expect(Timestamp(rawValue: 1_700_000_000).description == "1700000000")
        #expect(Timestamp(rawValue: -42).description == "-42")
        #expect(Timestamp(rawValue: Int64.max).description == "9223372036854775807")
    }

    @Test("a timestamp encodes as a bare number and decodes back", arguments: [Int64.min, 0, 1_700_000_000, Int64.max])
    func codableRoundTrip(seconds: Int64) throws {
        let timestamp = Timestamp(rawValue: seconds)
        let data = try JSONEncoder().encode(timestamp)

        #expect(String(decoding: data, as: UTF8.self) == String(seconds))
        #expect(try JSONDecoder().decode(Timestamp.self, from: data) == timestamp)
    }

    @Test("decoding a value that is not an integer fails", arguments: ["1700000000.5", "\"1700000000\"", "null"])
    func nonIntegerDecodingFails(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Timestamp.self, from: Data(json.utf8))
        }
    }

    /// The NIP-40 path: an expiration read off an untrusted event and written back out.
    @Test("a hostile expiration tag survives being re-emitted")
    func hostileExpirationRoundTrips() throws {
        let event = Event(
            id: try EventID(hex: String(repeating: "aa", count: 32)),
            publicKey: try PublicKey(hex: String(repeating: "bb", count: 32)),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .textNote,
            tags: [Event.Tag(name: .expiration, values: ["9223372036854775807"])],
            content: "",
            signature: try Signature(hex: String(repeating: "cc", count: 64)))

        let expiration = try #require(event.expiration)
        #expect(expiration.rawValue == Int64.max)
        // Feeding it straight back into the tag builder was the crashing path.
        let tag = Tag.expiration(expiration)

        #expect(tag.values == ["9223372036854775807"])
        #expect(event.isExpired(asOf: Timestamp(Date(timeIntervalSince1970: .infinity))) == false)
    }

    // MARK: - Arithmetic

    @Test(
        "advancing moves by the duration's whole seconds",
        arguments: [
            (Duration.seconds(60), Int64(1_700_000_060)),
            (.seconds(-60), 1_699_999_940),
            (.zero, 1_700_000_000),
        ])
    func advancedByWholeSeconds(duration: Duration, expected: Int64) {
        #expect(Timestamp(rawValue: 1_700_000_000).advanced(by: duration).rawValue == expected)
    }

    @Test(
        "advancing truncates the sub-second part toward zero",
        arguments: [
            (Duration.milliseconds(1_900), Int64(1_700_000_001)),
            (.milliseconds(-1_900), 1_699_999_999),
            (.milliseconds(999), 1_700_000_000),
            (.milliseconds(-999), 1_700_000_000),
        ])
    func advancedTruncatesFractions(duration: Duration, expected: Int64) {
        #expect(Timestamp(rawValue: 1_700_000_000).advanced(by: duration).rawValue == expected)
    }

    @Test("advancing past the bounds of Int64 saturates instead of trapping")
    func advancedSaturates() {
        #expect(Timestamp(rawValue: .max).advanced(by: .seconds(1)).rawValue == .max)
        #expect(Timestamp(rawValue: .min).advanced(by: .seconds(-1)).rawValue == .min)
        #expect(Timestamp(rawValue: 1).advanced(by: .seconds(Int64.max)).rawValue == .max)
        #expect(Timestamp(rawValue: -2).advanced(by: .seconds(Int64.min)).rawValue == .min)
        // Durations whose whole seconds do not fit in Int64 at all.
        #expect(Timestamp(rawValue: 0).advanced(by: .seconds(Int64.max) * 4).rawValue == .max)
        #expect(Timestamp(rawValue: 0).advanced(by: .seconds(Int64.min) * 4).rawValue == .min)
    }

    @Test("advancing by more than Int64 seconds lands exactly when the result fits")
    func advancedBeyondInt64SecondsWhenResultFits() {
        let span = Duration.seconds(Int64.max) + .seconds(Int64.max) + .milliseconds(500)
        #expect(Timestamp(rawValue: .min).advanced(by: span).rawValue == Int64.max - 1)
        #expect(Timestamp(rawValue: .max).advanced(by: .zero - span).rawValue == Int64.min + 1)
    }

    @Test("duration(to:) measures the signed distance in whole seconds")
    func durationTo() {
        let start = Timestamp(rawValue: 1_700_000_000)

        #expect(start.duration(to: Timestamp(rawValue: 1_700_000_090)) == .seconds(90))
        #expect(start.duration(to: Timestamp(rawValue: 1_699_999_910)) == .seconds(-90))
        #expect(start.duration(to: start) == .zero)
        let other = Timestamp(rawValue: 1_234_567_890)
        #expect(start.advanced(by: start.duration(to: other)) == other)
    }

    @Test("duration(to:) spans the full range of Int64 without overflowing")
    func durationToFullRange() {
        let span = Timestamp(rawValue: .min).duration(to: Timestamp(rawValue: .max))
        #expect(span == .seconds(Int64.max) + .seconds(Int64.max) + .seconds(1))
        #expect(Timestamp(rawValue: .min).advanced(by: span) == Timestamp(rawValue: .max))
    }

    @Test("an integer literal is Unix seconds")
    func integerLiteral() {
        let literal: Timestamp = 1_700_000_000
        #expect(literal == Timestamp(rawValue: 1_700_000_000))
        #expect(literal.date == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
