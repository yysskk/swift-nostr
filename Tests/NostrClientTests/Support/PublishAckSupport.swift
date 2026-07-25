import Foundation
import NostrCore
import NostrTestSupport

@testable import NostrClient

/// Shared helpers for acknowledging EVENT publishes on a ``MockWebSocketSession``,
/// so publish flows complete against a test-controlled relay.
enum PublishAckSupport {

    /// The EVENT frames sent on `socket` so far.
    static func eventFrames(in socket: MockWebSocketSession) -> [String] {
        socket.sentTextFrames.filter { $0.hasPrefix("[\"EVENT\"") }
    }

    /// Decodes the event carried by an `["EVENT", {...}]` client frame.
    static func event(inFrame frame: String) throws -> Event {
        guard let data = frame.data(using: .utf8),
            let array = try JSONSerialization.jsonObject(with: data) as? [Any],
            array.count >= 2,
            let eventDict = array[1] as? [String: Any]
        else {
            throw NostrError.invalidMessageFormat
        }
        let eventData = try JSONSerialization.data(withJSONObject: eventDict)
        return try JSONDecoder().decode(Event.self, from: eventData)
    }

    /// Waits for the EVENT frame at index `frame` on `socket`, delivers the relay's
    /// OK for it, and returns the sent event.
    @discardableResult
    static func acknowledgePublish(on socket: MockWebSocketSession, frame index: Int = 0) async throws -> Event {
        try await NIP42TestSupport.pollUntil { eventFrames(in: socket).count > index }
        let sent = try event(inFrame: eventFrames(in: socket)[index])
        socket.deliver(.string("[\"OK\",\"\(sent.id)\",true,\"\"]"))
        return sent
    }

    /// Runs `operation` while delivering the relay's OK for each of the `publishes`
    /// EVENT frames it sends on `socket`, returning the operation's result.
    @discardableResult
    static func acknowledgingPublishes<T: Sendable>(
        _ publishes: Int = 1,
        on socket: MockWebSocketSession,
        during operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let baseline = eventFrames(in: socket).count
        let task = Task { try await operation() }
        for offset in 0..<publishes {
            do {
                try await acknowledgePublish(on: socket, frame: baseline + offset)
            } catch {
                // The frame never appeared — most likely the operation itself failed,
                // so surface its error rather than the poll timeout.
                task.cancel()
                _ = try await task.value
                throw error
            }
        }
        return try await task.value
    }
}
