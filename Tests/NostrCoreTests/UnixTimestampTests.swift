import Foundation
import NostrCore
import Testing

/// A timestamp arrives from a relay as a decimal string, and the full `Int64` range does not
/// round-trip through `Date` — it stores a `Double`, and converting one back with `Int64(_:)` traps
/// on a value it cannot represent. Parsing such a tag and re-emitting it killed the process.
@Suite("Unix Timestamp Range Tests")
struct UnixTimestampTests {

    @Test(
        "an out-of-range timestamp clamps instead of trapping",
        arguments: [Int64.max, Int64.min, Int64.max - 1, 9_223_372_036_854_775_000]
    )
    func extremeSecondsSurviveTheRoundTrip(seconds: Int64) {
        let date = UnixTimestamp.date(fromSeconds: seconds)
        // The trap was here: converting the parsed Date back to seconds.
        let back = UnixTimestamp.seconds(from: date)

        #expect(UnixTimestamp.representableSeconds.contains(back))
    }

    @Test("ordinary timestamps round-trip exactly")
    func ordinaryTimestampsAreExact() {
        for seconds in [Int64(0), 1, 1_700_000_000, -1, -1_700_000_000] {
            let date = UnixTimestamp.date(fromSeconds: seconds)
            #expect(UnixTimestamp.seconds(from: date) == seconds)
        }
    }

    @Test("a non-finite date clamps rather than trapping")
    func nonFiniteDatesClamp() {
        #expect(
            UnixTimestamp.seconds(from: Date(timeIntervalSince1970: .infinity))
                == UnixTimestamp.representableSeconds.upperBound)
        #expect(
            UnixTimestamp.seconds(from: Date(timeIntervalSince1970: -.infinity))
                == UnixTimestamp.representableSeconds.lowerBound)
    }

    /// The NIP-40 path: an expiration read off an untrusted event and written back out.
    @Test("a hostile expiration tag survives being re-emitted")
    func hostileExpirationRoundTrips() throws {
        let event = Event(
            id: String(repeating: "aa", count: 32),
            pubkey: String(repeating: "bb", count: 32),
            createdAt: 1_700_000_000,
            kind: .textNote,
            tags: [["expiration", "9223372036854775807"]],
            content: "",
            sig: String(repeating: "cc", count: 64))

        let expiration = try #require(event.expiration)
        // Feeding it straight back into the tag builder is the crashing path.
        let tag = Tag.expiration(expiration)

        #expect(tag.values.first != nil)
        #expect(Int64(tag.values[0]) != nil)
    }
}
