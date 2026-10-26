import Foundation
import NostrCore
import Testing

@Suite("Relay Connection Config Tests")
struct RelayConnectionConfigTests {

    @Test("default configuration has the split timeouts")
    func defaultConfiguration() {
        let config = RelayConnectionConfig.default
        #expect(config.connectionTimeout == .seconds(10))
        #expect(config.sendTimeout == .seconds(10))
        #expect(config.publishAckTimeout == .seconds(30))
        #expect(config.queryTimeout == .seconds(10))
        #expect(config.pingInterval == .seconds(30))
        #expect(config.autoReconnect == true)
        #expect(config.maximumReconnectAttempts == 0)
        #expect(config.initialReconnectDelay == .seconds(1))
        #expect(config.maximumReconnectDelay == .seconds(60))
        #expect(config.reconnectBackoffMultiplier == 2.0)
        #expect(RelayConnectionConfig.minimumReconnectDelay == .milliseconds(100))
    }

    @Test("memberwise init resolves unambiguously to the new initializer")
    func memberwiseInitResolution() {
        let config = RelayConnectionConfig(autoReconnect: false)
        #expect(config.sendTimeout == .seconds(10))
        #expect(config.publishAckTimeout == .seconds(30))
        #expect(config.pingInterval == .seconds(30))
        #expect(config.autoReconnect == false)
    }

}
