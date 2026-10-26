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
            pubkey: try PublicKey(hex: String(repeating: "bb", count: 32)),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .textNote,
            tags: [["expiration", "9223372036854775807"]],
            content: "",
            signature: try Signature(hex: String(repeating: "cc", count: 64)))

        let expiration = try #require(event.expiration)
        #expect(expiration.rawValue == Int64.max)
        // Feeding it straight back into the tag builder was the crashing path.
        let tag = Tag.expiration(expiration)

        #expect(tag.values == ["9223372036854775807"])
        #expect(event.isExpired(asOf: Timestamp(Date(timeIntervalSince1970: .infinity))) == false)
    }
}
