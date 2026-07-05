import Foundation
import Testing

@testable import NostrConnect

@Suite("RemoteSigner Request Encoding Tests")
struct RemoteSignerRequestTests {
    @Test("sign_event round-trips through JSON with its method and params")
    func signEventRoundTrip() throws {
        let request = RemoteSignerRequest(method: .signEvent, params: ["{\"kind\":1}"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(RemoteSignerRequest.self, from: data)
        #expect(decoded.id == request.id)
        #expect(decoded.method == "sign_event")
        #expect(decoded.params == ["{\"kind\":1}"])
    }

    @Test("the encoded body carries id, method, and params keys")
    func encodesExpectedKeys() throws {
        let request = RemoteSignerRequest(id: "abc", method: .connect, params: ["pubkey", "secret"])
        let data = try JSONEncoder().encode(request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try #require(object)
        #expect(root["id"] as? String == "abc")
        #expect(root["method"] as? String == "connect")
        #expect(root["params"] as? [String] == ["pubkey", "secret"])
    }

    @Test("makeID yields unique 32-hex-character ids")
    func makeIDIsHexAndUnique() {
        let hexCharacters = Set("0123456789abcdef")
        var ids: Set<String> = []
        for _ in 0..<100 {
            let id = RemoteSignerRequest.makeID()
            #expect(id.count == 32)
            #expect(id.allSatisfy { hexCharacters.contains($0) })
            ids.insert(id)
        }
        #expect(ids.count == 100)
    }
}
