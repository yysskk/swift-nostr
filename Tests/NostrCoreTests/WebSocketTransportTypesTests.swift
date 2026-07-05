import Foundation
// Non-@testable import: also asserts these transport types are part of the public API.
import NostrCore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Locks in the public contract of the transport value types that a host transport
/// (e.g. an OkHttp-backed factory on Android) maps to and from.
@Suite("WebSocket Transport Type Tests")
struct WebSocketTransportTypesTests {

    /// Every close code the library defines, kept in sync with `WebSocketCloseCode`.
    /// The enum is not `CaseIterable`, so the cases are listed explicitly.
    private static let allCloseCodes: [WebSocketCloseCode] = [
        .normalClosure,
        .goingAway,
        .protocolError,
        .unsupportedData,
        .noStatusReceived,
        .abnormalClosure,
        .invalidFramePayloadData,
        .policyViolation,
        .messageTooBig,
        .mandatoryExtensionMissing,
        .internalServerError,
        .tlsHandshakeFailure,
    ]

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

    /// The `URLSession` transport maps each ``WebSocketCloseCode`` straight through
    /// its raw value. This asserts every case has a real
    /// `URLSessionWebSocketTask.CloseCode`, so the transport never needs the
    /// `.invalid` fallback that only backstops a future enum addition.
    @Test("every close code has a URLSession equivalent")
    func closeCodesMapToURLSession() {
        for closeCode in Self.allCloseCodes {
            #expect(URLSessionWebSocketTask.CloseCode(rawValue: closeCode.rawValue) != nil)
        }
    }
}
