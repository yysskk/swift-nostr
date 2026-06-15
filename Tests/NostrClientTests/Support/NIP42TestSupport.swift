import Foundation
import NostrCore

@testable import NostrClient

/// Shared helpers for the NIP-42 test suites.
enum NIP42TestSupport {

    /// Spins until `condition` holds, bounded so a logic error fails fast instead of hanging.
    static func pollUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NostrError.timeout
    }

    /// Extracts the event of the first AUTH frame sent on `mock`.
    static func sentAuthEvent(in mock: MockWebSocketSession) throws -> Event {
        guard let frame = mock.sentTextFrames.first(where: { $0.hasPrefix("[\"AUTH\"") }),
            let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let eventDict = array[1] as? [String: Any]
        else {
            throw NostrError.invalidMessageFormat
        }
        let eventData = try JSONSerialization.data(withJSONObject: eventDict)
        return try JSONDecoder().decode(Event.self, from: eventData)
    }

    /// Waits for the next AUTH frame `connection` sends, delivers the relay's
    /// OK `true` for it, and waits for the pubkey to be recorded.
    @discardableResult
    static func acknowledgeAuth(
        on connection: RelayConnection, mock: MockWebSocketSession
    ) async throws -> Event {
        try await pollUntil { mock.sentTextFrames.contains { $0.hasPrefix("[\"AUTH\"") } }
        let sent = try sentAuthEvent(in: mock)
        mock.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        try await pollUntil { await connection.isAuthenticated }
        return sent
    }
}
