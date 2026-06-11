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

    @available(*, deprecated, message: "Exercises the deprecated operationTimeout API on purpose")
    @Test("deprecated operationTimeout init fans out to all split timeouts")
    func deprecatedInitMapsOperationTimeout() {
        let config = RelayConnectionConfig(
            connectionTimeout: 5,
            operationTimeout: 42,
            autoReconnect: false,
            maxReconnectAttempts: 3
        )
        #expect(config.connectionTimeout == 5)
        #expect(config.sendTimeout == 42)
        #expect(config.publishAckTimeout == 42)
        #expect(config.pingInterval == 42)
        #expect(config.autoReconnect == false)
        #expect(config.maxReconnectAttempts == 3)
    }

    @available(*, deprecated, message: "Exercises the deprecated operationTimeout API on purpose")
    @Test("deprecated operationTimeout property reads the worst case and fans out writes")
    func deprecatedPropertyAccess() {
        var config = RelayConnectionConfig(publishAckTimeout: 21)
        #expect(config.operationTimeout == 21)

        config.sendTimeout = 50
        #expect(config.operationTimeout == 50)

        config.operationTimeout = 7
        #expect(config.sendTimeout == 7)
        #expect(config.publishAckTimeout == 7)
        #expect(config.pingInterval == 7)
    }
}
