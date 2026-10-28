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
        #expect(config.reconnect == .default)
    }

    @Test("memberwise init resolves unambiguously to the new initializer")
    func memberwiseInitResolution() {
        let config = RelayConnectionConfig(reconnect: nil)
        #expect(config.sendTimeout == .seconds(10))
        #expect(config.publishAckTimeout == .seconds(30))
        #expect(config.pingInterval == .seconds(30))
        #expect(config.reconnect == nil)
    }

}
