import Foundation
import Testing

@testable import NostrCore

@Suite("URIQuery Tests")
struct URIQueryTests {
    @Test("escapes the reserved characters inside values and keeps names verbatim")
    func encodesReservedCharacters() {
        let items = [
            URLQueryItem(name: "relay", value: "wss://relay.example/path?x=1#f"),
            URLQueryItem(name: "perms", value: "sign_event:1,nip44_encrypt"),
            URLQueryItem(name: "name", value: "a+b=c&d e"),
        ]

        let expected =
            "relay=wss%3A%2F%2Frelay.example%2Fpath%3Fx%3D1%23f"
            + "&perms=sign_event%3A1%2Cnip44_encrypt&name=a%2Bb%3Dc%26d%20e"
        #expect(URIQuery.encode(items) == expected)
    }

    @Test("skips items without a value")
    func skipsNilValues() {
        let items = [URLQueryItem(name: "a", value: nil), URLQueryItem(name: "b", value: "1")]
        #expect(URIQuery.encode(items) == "b=1")
    }

    @Test("encoded values decode back through URLComponents")
    func decodesThroughURLComponents() throws {
        let values = ["wss://relay.example/a%20b?k=v&w=x+y", "ünïcödé@例え.jp", "a,b:c/d"]
        let items = values.map { URLQueryItem(name: "v", value: $0) }
        let components = try #require(URLComponents(string: "x://h?" + URIQuery.encode(items)))
        let decoded = components.queryItems?.compactMap(\.value)
        #expect(decoded == values)
    }

    @Test("randomHex returns lowercase hex of the requested byte count")
    func randomHex() {
        let hex = URIQuery.randomHex(byteCount: 16)
        #expect(hex.count == 32)
        #expect(hex.isCanonicalHex(byteCount: 16))
        #expect(hex != URIQuery.randomHex(byteCount: 16))
    }
}
