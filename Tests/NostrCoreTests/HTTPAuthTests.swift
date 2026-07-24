import Crypto
import Foundation
import NostrCore
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("HTTP Auth Tests")
struct HTTPAuthTests {
    let url = URL(string: "https://api.example.com/upload?type=media")!

    @Test("authorization event carries the URL and method and verifies")
    func authorizationEventShape() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await HTTPAuth.authorizationEvent(url: url, method: "GET", signer: signer)

        #expect(event.kind == .httpAuth)
        #expect(event.content.isEmpty)
        #expect(event.firstTagValue(named: "u") == "https://api.example.com/upload?type=media")
        #expect(event.firstTagValue(named: "method") == "GET")
        #expect(event.firstTagValue(named: "payload") == nil)
        #expect(event.pubkey == signer.publicKey)
        #expect(try event.verify())
    }

    @Test("the method is uppercased in the method tag")
    func methodIsUppercased() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let event = try await HTTPAuth.authorizationEvent(url: url, method: "post", signer: signer)

        #expect(event.firstTagValue(named: "method") == "POST")
    }

    @Test("a payload adds its SHA-256 hex as a payload tag")
    func payloadTag() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let body = Data("{\"name\":\"nostr\"}".utf8)

        let event = try await HTTPAuth.authorizationEvent(
            url: url, method: "POST", payload: body, signer: signer)

        let expectedHash = Data(SHA256.hash(data: body)).hexEncodedString()
        #expect(event.firstTagValue(named: "payload") == expectedHash)
    }

    @Test("createdAt stamps the event timestamp")
    func createdAtIsStamped() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let createdAt = Date(timeIntervalSince1970: 1_682_327_852)

        let event = try await HTTPAuth.authorizationEvent(
            url: url, method: "GET", createdAt: createdAt, signer: signer)

        #expect(event.createdAt == 1_682_327_852)
    }

    @Test("the header value is the Nostr scheme plus the base64 event JSON")
    func headerValueRoundTrips() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let event = try await HTTPAuth.authorizationEvent(url: url, method: "GET", signer: signer)

        let value = try HTTPAuth.authorizationHeaderValue(for: event)

        let parts = value.split(separator: " ")
        try #require(parts.count == 2)
        #expect(parts[0] == "Nostr")
        let json = try #require(Data(base64Encoded: String(parts[1])))
        let decoded = try JSONDecoder().decode(Event.self, from: json)
        #expect(decoded == event)
    }

    @Test("encoding a non-27235 event as a header is rejected")
    func headerValueRejectsWrongKind() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let note = try signer.sign(
            UnsignedEvent(pubkey: signer.publicKey, kind: .textNote, content: "hi"))

        #expect(throws: NostrError.invalidData) {
            try HTTPAuth.authorizationHeaderValue(for: note)
        }
    }

    @Test("the one-call header convenience matches the two-step form")
    func oneCallHeaderConvenience() async throws {
        let signer = EventSigner(keyPair: try KeyPair())

        let value = try await HTTPAuth.authorizationHeaderValue(
            url: url, method: "get", signer: signer)

        let parts = value.split(separator: " ")
        try #require(parts.count == 2)
        let json = try #require(Data(base64Encoded: String(parts[1])))
        let event = try JSONDecoder().decode(Event.self, from: json)
        #expect(event.kind == .httpAuth)
        #expect(event.firstTagValue(named: "u") == url.absoluteString)
        #expect(event.firstTagValue(named: "method") == "GET")
        #expect(try event.verify())
    }

    @Test("URLRequest convenience signs the URL, method, and body")
    func urlRequestConvenience() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let body = Data("payload".utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body

        try await request.setNostrAuthorization(signer: signer)

        let value = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let parts = value.split(separator: " ")
        try #require(parts.count == 2)
        #expect(parts[0] == "Nostr")
        let json = try #require(Data(base64Encoded: String(parts[1])))
        let event = try JSONDecoder().decode(Event.self, from: json)
        #expect(event.firstTagValue(named: "u") == url.absoluteString)
        #expect(event.firstTagValue(named: "method") == "POST")
        #expect(
            event.firstTagValue(named: "payload")
                == Data(SHA256.hash(data: body)).hexEncodedString())
        #expect(try event.verify())
    }

    @Test("URLRequest convenience defaults the method to GET")
    func urlRequestDefaultsToGET() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        var request = URLRequest(url: url)

        try await request.setNostrAuthorization(signer: signer)

        let value = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let json = try #require(Data(base64Encoded: String(value.dropFirst("Nostr ".count))))
        let event = try JSONDecoder().decode(Event.self, from: json)
        #expect(event.firstTagValue(named: "method") == "GET")
        #expect(event.firstTagValue(named: "payload") == nil)
    }

    @Test("NIP-98 tag constructors produce the spec tag shapes")
    func tagConstructors() {
        #expect(Tag.url("https://example.com/?a=b").rawArray == ["u", "https://example.com/?a=b"])
        #expect(Tag.method("GET").rawArray == ["method", "GET"])
        #expect(Tag.payload(sha256: "abc123").rawArray == ["payload", "abc123"])
    }

    @Test("kind 27235 is ephemeral and named httpAuth")
    func kindConstant() {
        #expect(Event.Kind.httpAuth.rawValue == 27235)
        #expect(Event.Kind.httpAuth.isEphemeral)
    }
}
