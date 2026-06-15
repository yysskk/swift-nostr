import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("Relay Connection Connect Tests")
struct RelayConnectionConnectTests {

    /// Nothing listens on this loopback port; connection attempts fail fast and
    /// are bounded by the 1-second connection timeout in the worst case.
    private func makeUnreachableConnection() -> RelayConnection {
        RelayConnection(
            url: URL(string: "ws://127.0.0.1:9")!,
            config: RelayConnectionConfig(connectionTimeout: 1)
        )
    }

    @Test("concurrent connect callers share the in-flight attempt's outcome")
    func concurrentConnectSharesOutcome() async {
        let connection = makeUnreachableConnection()

        // Before in-flight sharing, a caller arriving while another task was still
        // connecting returned immediately as success with an unestablished socket.
        // Every concurrent caller must observe the real (failed) outcome.
        let outcomes = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    do {
                        try await connection.connect()
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        #expect(outcomes == [false, false, false, false])
        let state = await connection.state
        #expect(state != .connected)
    }

    @Test("a settled attempt is not reused by later connect calls")
    func settledAttemptIsNotReused() async {
        let connection = makeUnreachableConnection()

        await #expect(throws: NostrError.self) {
            try await connection.connect()
        }
        // The first attempt has settled; a fresh call must start (and fail) anew
        // rather than reuse the finished task or hang.
        await #expect(throws: NostrError.self) {
            try await connection.connect()
        }
    }
}
