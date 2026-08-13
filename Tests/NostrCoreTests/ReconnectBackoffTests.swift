import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

/// Every reconnection field on `RelayConnectionConfig` is a `var`, so a value set after
/// initialization would slip past validation done there. The bounds are resolved where the delay is
/// read instead, which is also where a degenerate value would do its damage: with the default of
/// unlimited attempts, a zero delay is an unbounded loop hammering the relay with no pause at all.
@Suite("Reconnect Backoff Bounds Tests")
struct ReconnectBackoffTests {

    // MARK: - Degenerate configuration

    @Test(
        "a delay that would never pause is floored",
        arguments: [0, -1, -100, 0.0001]
    )
    func degenerateInitialDelayIsFloored(delay: TimeInterval) {
        var config = RelayConnectionConfig()
        config.initialReconnectDelay = delay

        #expect(config.resolvedInitialReconnectDelay == RelayConnectionConfig.minimumReconnectDelay)
        #expect(config.boundedReconnectDelay(delay) == RelayConnectionConfig.minimumReconnectDelay)
    }

    /// The floor has to hold for a value assigned after `init`, which is the case validation in the
    /// initializer would miss entirely.
    @Test("a delay mutated after initialization is still floored")
    func mutatedDelayIsFloored() {
        var config = RelayConnectionConfig(initialReconnectDelay: 5)
        #expect(config.resolvedInitialReconnectDelay == 5)

        config.initialReconnectDelay = 0
        #expect(config.resolvedInitialReconnectDelay == RelayConnectionConfig.minimumReconnectDelay)
    }

    /// Zero times any multiplier is zero, so without the floor the backoff could never grow away
    /// from a zero start — the loop would spin at full speed forever.
    @Test("backoff grows away from a degenerate starting delay")
    func backoffGrowsFromDegenerateStart() {
        var config = RelayConnectionConfig(reconnectBackoffMultiplier: 2)
        config.initialReconnectDelay = 0

        var delay = config.resolvedInitialReconnectDelay
        var seen: [TimeInterval] = [delay]
        for _ in 0..<4 {
            delay = config.boundedReconnectDelay(delay * config.resolvedBackoffMultiplier)
            seen.append(delay)
        }

        #expect(seen == [0.1, 0.2, 0.4, 0.8, 1.6])
    }

    @Test(
        "a multiplier below one cannot shrink the delay",
        arguments: [0.0, 0.5, -2.0]
    )
    func multiplierBelowOneIsFloored(multiplier: Double) {
        var config = RelayConnectionConfig()
        config.reconnectBackoffMultiplier = multiplier

        #expect(config.resolvedBackoffMultiplier == 1)

        let delay = config.resolvedInitialReconnectDelay
        #expect(config.boundedReconnectDelay(delay * config.resolvedBackoffMultiplier) == delay)
    }

    /// A multiplier of exactly 1 is a deliberate choice — retry at a fixed rate — and is left alone.
    @Test("a multiplier of one holds the delay steady")
    func multiplierOfOneIsPreserved() {
        var config = RelayConnectionConfig(initialReconnectDelay: 2)
        config.reconnectBackoffMultiplier = 1

        #expect(config.resolvedBackoffMultiplier == 1)
        #expect(config.boundedReconnectDelay(2 * 1) == 2)
    }

    @Test("the delay is capped at the configured maximum")
    func delayIsCapped() {
        let config = RelayConnectionConfig(
            initialReconnectDelay: 1, maxReconnectDelay: 5, reconnectBackoffMultiplier: 10)

        #expect(config.boundedReconnectDelay(1 * 10) == 5)
        #expect(config.boundedReconnectDelay(1_000) == 5)
    }

    /// A ceiling below the floor would otherwise clamp every delay back under the minimum.
    @Test("a maximum below the initial delay is raised to it")
    func maxBelowInitialIsRaised() {
        var config = RelayConnectionConfig(initialReconnectDelay: 10)
        config.maxReconnectDelay = 1

        #expect(config.resolvedMaxReconnectDelay == 10)
        #expect(config.boundedReconnectDelay(10) == 10)
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
            url: URL(string: "wss://relay.example.com")!,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets.next() }),
            config: RelayConnectionConfig(autoReconnect: true, initialReconnectDelay: 0),
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
            url: URL(string: "wss://relay.example.com")!,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { sockets.next() }),
            config: RelayConnectionConfig(
                autoReconnect: true, initialReconnectDelay: 0, reconnectBackoffMultiplier: 0),
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
        throw NostrError.timeout
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
