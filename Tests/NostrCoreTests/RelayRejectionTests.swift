import Foundation
import NostrTestSupport
import Testing

@testable import NostrCore

@Suite("Relay Rejection Tests")
struct RelayRejectionTests {
    // MARK: - Parsing

    @Test("a status with a prefix splits into the prefix and the human-readable message")
    func parsesPrefix() {
        let rejection = RelayRejection(status: "pow: difficulty 28 required")
        #expect(rejection.prefix == .pow)
        #expect(rejection.message == "difficulty 28 required")
        #expect(rejection == RelayRejection(prefix: .pow, message: "difficulty 28 required"))
    }

    @Test("an unknown prefix is preserved")
    func parsesUnknownPrefix() {
        let rejection = RelayRejection(status: "payment-required: subscribe first")
        #expect(rejection.prefix == RelayResponsePrefix(rawValue: "payment-required"))
        #expect(rejection.message == "subscribe first")
    }

    @Test("a status without a colon has no prefix and keeps the whole string")
    func parsesWithoutPrefix() {
        let rejection = RelayRejection(status: "not today")
        #expect(rejection.prefix == nil)
        #expect(rejection.message == "not today")
    }

    @Test("prose that happens to contain a colon is not a prefix")
    func parsesProseWithColon() {
        let rejection = RelayRejection(status: "try again later: the relay is busy")
        #expect(rejection.prefix == nil)
        #expect(rejection.message == "try again later: the relay is busy")
    }

    @Test("a prefix with nothing after it leaves an empty message")
    func parsesBarePrefix() {
        let rejection = RelayRejection(status: "blocked:")
        #expect(rejection.prefix == .blocked)
        #expect(rejection.message == "")
    }

    @Test("only the whitespace after the prefix's colon is stripped")
    func stripsLeadingWhitespaceOnly() {
        let rejection = RelayRejection(status: "invalid:   bad: tag ")
        #expect(rejection.prefix == .invalid)
        #expect(rejection.message == "bad: tag ")
    }

    @Test("an empty status has no prefix and an empty message")
    func parsesEmptyStatus() {
        let rejection = RelayRejection(status: "")
        #expect(rejection.prefix == nil)
        #expect(rejection.message == "")
    }

    // MARK: - Description

    @Test(
        "the description recombines the prefix and the message",
        arguments: [
            ("pow: difficulty 28 required", "The relay rejected the request: pow: difficulty 28 required"),
            ("blocked:", "The relay rejected the request: blocked"),
            ("not today", "The relay rejected the request: not today"),
            ("", "The relay rejected the request"),
        ])
    func describesRejection(status: String, description: String) {
        #expect(RelayRejection(status: status).errorDescription == description)
    }

    @Test("an authentication rejection describes the relay's status")
    func describesAuthenticationRejection() {
        let error = RelayConnection.Error.authenticationRejected(
            RelayRejection(prefix: .restricted, message: "not allowed"))
        #expect(error.errorDescription == "The relay rejected the authentication event: restricted: not allowed")
    }
}

/// A publish answered with OK `false` and a COUNT answered with CLOSED surface the relay's
/// status as a ``RelayRejection``, so callers branch on its prefix rather than its wording.
@Suite("Relay Rejection Surfacing Tests")
struct RelayRejectionSurfacingTests {
    private let relayURL = RelayURL("wss://relay.example.com")!

    private func makeConnection(
        socket: MockWebSocketSession,
        publishAckTimeout: Duration = .seconds(30)
    ) -> RelayConnection {
        RelayConnection(
            url: relayURL,
            webSocketFactory: MockWebSocketSessionFactory(makeSession: { socket }),
            config: RelayConnectionConfig(publishAckTimeout: publishAckTimeout, autoReconnect: false)
        )
    }

    private func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition never became true")
    }

    private func publishRejected(withStatus status: String) async throws -> RelayRejection? {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let event = try await EventSigner(keyPair: try KeyPair()).sign(.textNote("hello"))
        let publish = Task { try await connection.publish(event) }
        try await pollUntil { socket.sentTextFrames.contains { $0.contains(event.id.hex) } }
        socket.deliver(.string("[\"OK\",\"\(event.id)\",false,\"\(status)\"]"))

        let result = await publish.result
        await connection.disconnect()
        return try result.map { nil }.flatMapError { error in
            (error as? RelayRejection).map { .success($0) } ?? .failure(error)
        }.get()
    }

    @Test("a publish rejected for proof of work throws a rejection with the pow prefix")
    func publishRejectionCarriesPrefix() async throws {
        let rejection = try await publishRejected(withStatus: "pow: difficulty 28 required")
        #expect(rejection == RelayRejection(prefix: .pow, message: "difficulty 28 required"))
    }

    @Test("a publish rejected without a prefix throws a rejection with a nil prefix")
    func publishRejectionWithoutPrefix() async throws {
        let rejection = try await publishRejected(withStatus: "go away: we are closed")
        #expect(rejection == RelayRejection(prefix: nil, message: "go away: we are closed"))
    }

    @Test("a COUNT closed by the relay throws a rejection with the relay's prefix")
    func countRejectionCarriesPrefix() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket)
        try await connection.connect()

        let count = Task { try await connection.countEvents(matching: [Filter(kinds: [1])]) }
        try await pollUntil { socket.sentTextFrames.contains { $0.hasPrefix("[\"COUNT\"") } }
        let frame = try #require(socket.sentTextFrames.first { $0.hasPrefix("[\"COUNT\"") })
        let array = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [Any])
        let subscriptionID = try #require(array[1] as? String)
        socket.deliver(.string("[\"CLOSED\",\"\(subscriptionID)\",\"rate-limited: slow down\"]"))

        await #expect(throws: RelayRejection(prefix: .rateLimited, message: "slow down")) {
            try await count.value
        }
        await connection.disconnect()
    }

    @Test("a publish the relay never acknowledges times out")
    func publishTimesOut() async throws {
        let socket = MockWebSocketSession()
        let connection = makeConnection(socket: socket, publishAckTimeout: .milliseconds(50))
        try await connection.connect()

        let event = try await EventSigner(keyPair: try KeyPair()).sign(.textNote("hello"))
        await #expect(throws: RelayConnection.Error.timedOut) {
            try await connection.publish(event)
        }
        await connection.disconnect()
    }
}
