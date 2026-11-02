import Foundation
import NostrCore
import Testing

@Suite("Relay Connection State Tests")
struct RelayConnectionStateTests {

    @Test(
        "a failure's description names the operation and keeps the reason",
        arguments: [
            (RelayConnectionState.Failure.Operation.connect, "Could not connect to the relay: offline"),
            (.keepalive, "The relay stopped answering keepalive pings: offline"),
            (.send, "Could not send to the relay: offline"),
            (.receive, "The connection to the relay dropped: offline"),
        ])
    func failureDescription(operation: RelayConnectionState.Failure.Operation, expected: String) {
        let failure = RelayConnectionState.Failure(operation: operation, reason: "offline")

        #expect(failure.errorDescription == expected)
        #expect(failure.localizedDescription == expected)
    }

    @Test("failures differ by operation and by reason")
    func failureEquality() {
        let failure = RelayConnectionState.Failure(operation: .send, reason: "offline")

        #expect(failure == RelayConnectionState.Failure(operation: .send, reason: "offline"))
        #expect(failure != RelayConnectionState.Failure(operation: .receive, reason: "offline"))
        #expect(failure != RelayConnectionState.Failure(operation: .send, reason: "timed out"))
    }
}
