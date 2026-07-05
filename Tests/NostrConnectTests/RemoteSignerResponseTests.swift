import Foundation
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Response Decoding Tests")
struct RemoteSignerResponseTests {
    private func decode(_ json: String) throws -> RemoteSignerResponse {
        try JSONDecoder().decode(RemoteSignerResponse.self, from: Data(json.utf8))
    }

    @Test("decodes a success result with no error")
    func decodeResult() throws {
        let response = try decode(#"{"id":"1","result":"ack"}"#)
        #expect(response.id == "1")
        #expect(response.result == "ack")
        #expect(response.error == nil)
        #expect(response.isAuthChallenge == false)
    }

    @Test("decodes an error response with no result")
    func decodeError() throws {
        let response = try decode(#"{"id":"1","error":"boom"}"#)
        #expect(response.id == "1")
        #expect(response.result == nil)
        #expect(response.error == "boom")
        #expect(response.isAuthChallenge == false)
    }

    @Test("an auth_url result with a URL in error is an auth challenge")
    func decodeAuthChallenge() throws {
        let response = try decode(#"{"id":"1","result":"auth_url","error":"https://signer.example/auth"}"#)
        #expect(response.isAuthChallenge == true)
        #expect(response.error == "https://signer.example/auth")
    }

    @Test("a normal result is not an auth challenge")
    func normalResultIsNotAuthChallenge() throws {
        let response = try decode(#"{"id":"1","result":"pong"}"#)
        #expect(response.isAuthChallenge == false)
    }
}
