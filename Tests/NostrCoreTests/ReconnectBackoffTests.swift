import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// Every field on `ReconnectPolicy` is a `var`, so a value set after initialization would slip
/// past validation done there. The bounds are resolved where the delay is read instead, which is
/// also where a degenerate value would do its damage: with unlimited attempts, a zero delay is an
/// unbounded loop hammering the relay with no pause at all.
@Suite("Reconnect Backoff Bounds Tests")
struct ReconnectBackoffTests {

    // MARK: - Defaults

    @Test("the default policy reconnects forever, doubling from 1 s up to 60 s")
    func defaultPolicy() {
        let policy = ReconnectPolicy.default
        #expect(policy.maximumAttempts == nil)
        #expect(policy.initialDelay == .seconds(1))
        #expect(policy.maximumDelay == .seconds(60))
        #expect(policy.backoffMultiplier == 2)
        #expect(ReconnectPolicy.minimumDelay == .milliseconds(100))
        #expect(policy == ReconnectPolicy())
    }

    @Test("the default delays double and cap at the maximum")
    func defaultDelaySequence() {
        let policy = ReconnectPolicy.default

        var delay = policy.resolvedInitialDelay
        var seen: [Duration] = [delay]
        for _ in 0..<7 {
            delay = policy.nextDelay(after: delay)
            seen.append(delay)
        }

        let expected: [Duration] = [1, 2, 4, 8, 16, 32, 60, 60].map { .seconds($0) }
        #expect(seen == expected)
    }

    // MARK: - Attempt limit

    @Test("no limit allows every attempt")
    func unlimitedAttempts() {
        let policy = ReconnectPolicy(maximumAttempts: nil)
        #expect(policy.allowsAttempt(after: 0))
        #expect(policy.allowsAttempt(after: 1_000_000))
    }

    @Test("a limit allows exactly that many attempts")
    func limitedAttempts() {
        let policy = ReconnectPolicy(maximumAttempts: 3)
        #expect(policy.allowsAttempt(after: 0))
        #expect(policy.allowsAttempt(after: 2))
        #expect(!policy.allowsAttempt(after: 3))
    }

    /// Zero no longer means unlimited — that is `nil` now — so it reads literally: no attempts.
    @Test("a limit of zero or below allows no attempt", arguments: [0, -1, Int.min])
    func nonPositiveLimitAllowsNoAttempt(limit: Int) {
        let policy = ReconnectPolicy(maximumAttempts: limit)
        #expect(!policy.allowsAttempt(after: 0))
    }

    // MARK: - Degenerate configuration

    @Test(
        "a delay that would never pause is floored",
        arguments: [Duration.zero, .seconds(-1), .seconds(-100), .microseconds(100)]
    )
    func degenerateInitialDelayIsFloored(delay: Duration) {
        var policy = ReconnectPolicy()
        policy.initialDelay = delay

        #expect(policy.resolvedInitialDelay == ReconnectPolicy.minimumDelay)
        #expect(policy.boundedDelay(delay) == ReconnectPolicy.minimumDelay)
    }

    /// The floor has to hold for a value assigned after `init`, which is the case validation in the
    /// initializer would miss entirely.
    @Test("a delay mutated after initialization is still floored")
    func mutatedDelayIsFloored() {
        var policy = ReconnectPolicy(initialDelay: .seconds(5))
        #expect(policy.resolvedInitialDelay == .seconds(5))

        policy.initialDelay = .zero
        #expect(policy.resolvedInitialDelay == ReconnectPolicy.minimumDelay)
    }

    /// Zero times any multiplier is zero, so without the floor the backoff could never grow away
    /// from a zero start — the loop would spin at full speed forever.
    @Test("backoff grows away from a degenerate starting delay")
    func backoffGrowsFromDegenerateStart() {
        var policy = ReconnectPolicy(backoffMultiplier: 2)
        policy.initialDelay = .zero

        var delay = policy.resolvedInitialDelay
        var seen: [Duration] = [delay]
        for _ in 0..<4 {
            delay = policy.nextDelay(after: delay)
            seen.append(delay)
        }

        let expected: [Duration] = [100, 200, 400, 800, 1600].map { .milliseconds($0) }
        #expect(seen == expected)
    }

    @Test(
        "a multiplier below one cannot shrink the delay",
        arguments: [0.0, 0.5, -2.0]
    )
    func multiplierBelowOneIsFloored(multiplier: Double) {
        var policy = ReconnectPolicy()
        policy.backoffMultiplier = multiplier

        #expect(policy.resolvedBackoffMultiplier == 1)

        let delay = policy.resolvedInitialDelay
        #expect(policy.nextDelay(after: delay) == delay)
    }

    /// A multiplier of exactly 1 is a deliberate choice — retry at a fixed rate — and is left alone.
    @Test("a multiplier of one holds the delay steady")
    func multiplierOfOneIsPreserved() {
        var policy = ReconnectPolicy(initialDelay: .seconds(2))
        policy.backoffMultiplier = 1

        #expect(policy.resolvedBackoffMultiplier == 1)
        #expect(policy.nextDelay(after: .seconds(2)) == .seconds(2))
    }

    @Test("the delay is capped at the configured maximum")
    func delayIsCapped() {
        let policy = ReconnectPolicy(initialDelay: .seconds(1), maximumDelay: .seconds(5), backoffMultiplier: 10)

        #expect(policy.nextDelay(after: .seconds(1)) == .seconds(5))
        #expect(policy.boundedDelay(.seconds(1_000)) == .seconds(5))
    }

    /// Multiplying a `Duration` by a non-finite or huge factor traps, so these must be absorbed
    /// before the next delay is formed.
    @Test(
        "a non-finite or huge multiplier never traps",
        arguments: [Double.nan, .infinity, 1e300]
    )
    func extremeMultiplierIsAbsorbed(multiplier: Double) {
        var policy = ReconnectPolicy(initialDelay: .seconds(1), maximumDelay: .seconds(60))
        policy.backoffMultiplier = multiplier

        let next = policy.nextDelay(after: .seconds(1))
        #expect(next == (multiplier.isNaN ? .seconds(1) : .seconds(60)))
    }

    /// A ceiling below the floor would otherwise clamp every delay back under the minimum.
    @Test("a maximum below the initial delay is raised to it")
    func maximumBelowInitialIsRaised() {
        var policy = ReconnectPolicy(initialDelay: .seconds(10))
        policy.maximumDelay = .seconds(1)

        #expect(policy.resolvedMaximumDelay == .seconds(10))
        #expect(policy.boundedDelay(.seconds(10)) == .seconds(10))
    }

    // MARK: - Jitter through a live reconnect

    /// Relays behind one flaky uplink fail together and would retry in lockstep, arriving as a
    /// thundering herd. The draw is injected so the randomization can be asserted by its bounds
    /// rather than by whatever the system generator happened to return.
    @Test("the reconnect wait is drawn from half to all of the delay")
    func jitterRangeIsHalfToWhole() async throws {
        let ranges = RecordedRanges()
        let sockets = ReconnectSocketSequence()
        let connection = RelayConnection(
            url: RelayURL("wss://relay.example.com")!,
            config: RelayConnectionConfig(reconnect: ReconnectPolicy(initialDelay: .zero)),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets.next() }),
            jitter: { range in
                ranges.record(range)
                return range.lowerBound
            }
        )

        try await connection.connect()
        sockets.at(0).deliver(error: URLError(.networkConnectionLost))

        // The reconnect establishes a second socket, so the floored delay still elapses in a test.
        try await pollUntil { sockets.count >= 2 && sockets.at(1).didResume }

        #expect(ranges.recorded == [0.5...1.0])
        await connection.disconnect()
    }

    /// A degenerate delay must still reconnect — the floor bounds the retry rate without
    /// disabling recovery.
    @Test("a connection configured with no delay still reconnects")
    func degenerateConfigStillReconnects() async throws {
        let sockets = ReconnectSocketSequence()
        let connection = RelayConnection(
            url: RelayURL("wss://relay.example.com")!,
            config: RelayConnectionConfig(reconnect: ReconnectPolicy(initialDelay: .zero, backoffMultiplier: 0)),
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets.next() }),
            jitter: { $0.lowerBound }
        )

        try await connection.connect()
        sockets.at(0).deliver(error: URLError(.networkConnectionLost))

        try await pollUntil { sockets.count >= 2 && sockets.at(1).didResume }
        #expect(await connection.state == .connected)

        await connection.disconnect()
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw RelayConnection.Error.timedOut
    }
}

/// Records the ranges the jitter seam was asked to draw from.
private final class RecordedRanges: @unchecked Sendable {
    private let lock = NSLock()
    private var ranges: [ClosedRange<Double>] = []

    func record(_ range: ClosedRange<Double>) {
        lock.lock()
        defer { lock.unlock() }
        ranges.append(range)
    }

    var recorded: [ClosedRange<Double>] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }
}

/// Hands out a fresh socket per connection attempt and keeps them addressable by attempt order.
private final class ReconnectSocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [MockWebSocketSession] = []

    func next() -> MockWebSocketSession {
        let socket = MockWebSocketSession()
        lock.lock()
        sockets.append(socket)
        lock.unlock()
        return socket
    }

    func at(_ index: Int) -> MockWebSocketSession {
        lock.lock()
        defer { lock.unlock() }
        return sockets[index]
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return sockets.count
    }
}
