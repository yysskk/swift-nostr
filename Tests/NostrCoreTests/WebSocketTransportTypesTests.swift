import Foundation
// Non-@testable import: also asserts these transport types are part of the public API.
import NostrCore
import Testing

/// Locks in the public contract of the transport value types that a host transport
/// (e.g. an OkHttp-backed factory on Android) maps to and from.
@Suite("WebSocket Transport Type Tests")
struct WebSocketTransportTypesTests {

    @Test("close codes carry their RFC 6455 status numbers")
    func closeCodeRawValues() {
        #expect(WebSocketCloseCode.normalClosure.rawValue == 1000)
        #expect(WebSocketCloseCode.goingAway.rawValue == 1001)
        #expect(WebSocketCloseCode.abnormalClosure.rawValue == 1006)
        #expect(WebSocketCloseCode.internalServerError.rawValue == 1011)
        #expect(WebSocketCloseCode(rawValue: 1000) == .normalClosure)
    }

    @Test("messages compare by frame kind and payload")
    func messageEquatable() {
        #expect(WebSocketMessage.string("a") == .string("a"))
        #expect(WebSocketMessage.string("a") != .string("b"))
        #expect(WebSocketMessage.data(Data([0x01])) == .data(Data([0x01])))
        #expect(WebSocketMessage.string("a") != .data(Data()))
    }
}
