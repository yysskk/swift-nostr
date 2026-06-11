import Foundation
import Testing

@testable import NostrClient

@Suite("Relay Connection Config Tests")
struct RelayConnectionConfigTests {

    @Test("default configuration has the split timeouts")
    func defaultConfiguration() {
        let config = RelayConnectionConfig.default
        #expect(config.connectionTimeout == 10)
        #expect(config.sendTimeout == 10)
        #expect(config.publishAckTimeout == 30)
        #expect(config.pingInterval == 30)
        #expect(config.autoReconnect == true)
        #expect(config.maxReconnectAttempts == 0)
        #expect(config.initialReconnectDelay == 1)
        #expect(config.maxReconnectDelay == 60)
        #expect(config.reconnectBackoffMultiplier == 2.0)
    }

    @Test("memberwise init resolves unambiguously to the new initializer")
    func memberwiseInitResolution() {
        let config = RelayConnectionConfig(autoReconnect: false)
        #expect(config.sendTimeout == 10)
        #expect(config.publishAckTimeout == 30)
        #expect(config.pingInterval == 30)
        #expect(config.autoReconnect == false)
    }

}
