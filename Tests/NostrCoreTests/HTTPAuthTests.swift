import Crypto
import Foundation
import NostrCore
import NostrTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("HTTP Auth Tests")
struct HTTPAuthTests {
    let url = URL(string: "https://api.example.com/upload?type=media")!

    @Test("httpAuthorization is kind 27235 with the u and method tags and empty content")
    func templateShape() {
        let template = EventTemplate.httpAuthorization(url: url, method: "GET")

        #expect(template.kind == .httpAuth)
        #expect(template.content.isEmpty)
        #expect(
            template.tags.map(\.rawArray) == [
                ["u", "https://api.example.com/upload?type=media"], ["method", "GET"],
            ])
    }

    @Test("the method is uppercased in the method tag")
    func methodIsUppercased() {
        let template = EventTemplate.httpAuthorization(url: url, method: "post")

        #expect(template.tags.map(\.rawArray) == [["u", url.absoluteString], ["method", "POST"]])
    }

    @Test("a payload adds its lowercase SHA-256 hex as a trailing payload tag")
    func payloadTag() {
        let body = Data("{\"name\":\"nostr\"}".utf8)

        let template = EventTemplate.httpAuthorization(url: url, method: "POST", payload: body)

        #expect(
            template.tags.map(\.rawArray) == [
                ["u", url.absoluteString],
                ["method", "POST"],
                ["payload", "eacc5f0b252fb35f1cea4cdf251b6e6a37cafa151228ca0112520ffe299cb2eb"],
            ])
    }

    @Test("an authorization event signed by a remote signer keeps the template and verifies")
    func remoteSignedEvent() async throws {
        let signer = StubRemoteSigner(keyPair: KeyPair())
        var template = EventTemplate.httpAuthorization(url: url, method: "get")
        template.createdAt = Timestamp(rawValue: 1_682_327_852)

        let event = try await signer.sign(template)

        #expect(event.kind == .httpAuth)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(event.createdAt.rawValue == 1_682_327_852)
        #expect(event.tags == [["u", url.absoluteString], ["method", "GET"]])
        #expect(try event.verify())
    }

    @Test("the header value is the Nostr scheme plus the base64 event JSON")
    func headerValueRoundTrips() throws {
        let signer = EventSigner(keyPair: KeyPair())
        let event = signer.sign(.httpAuthorization(url: url, method: "GET"))

        let value = try HTTPAuth.authorizationHeaderValue(for: event)

        let parts = value.split(separator: " ")
        try #require(parts.count == 2)
        #expect(parts[0] == "Nostr")
        let json = try #require(Data(base64Encoded: String(parts[1])))
        let decoded = try JSONDecoder().decode(Event.self, from: json)
        #expect(decoded == event)
    }

    @Test("encoding a non-27235 event as a header is rejected")
    func headerValueRejectsWrongKind() throws {
        let note = EventSigner(keyPair: KeyPair()).sign(.textNote("hi"))

        #expect(throws: HTTPAuth.AuthorizationError.invalidEventKind(.textNote)) {
            try HTTPAuth.authorizationHeaderValue(for: note)
        }
    }

    @Test("URLRequest convenience signs the URL, method, and body into a header that validates")
    func urlRequestConvenience() async throws {
        let signer = StubRemoteSigner(keyPair: KeyPair())
        let body = Data("payload".utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "post"
        request.httpBody = body

        try await request.setNostrAuthorization(signer: signer)

        let value = try #require(request.value(forHTTPHeaderField: "Authorization"))
        #expect(value.hasPrefix("Nostr "))
        let event = try HTTPAuth.validate(authorization: value, url: url, method: "POST", payload: body)
        #expect(event.publicKey == signer.keyPair.publicKey)
        #expect(
            event.tags == [
                ["u", url.absoluteString],
                ["method", "POST"],
                ["payload", Data(SHA256.hash(data: body)).hexEncodedString()],
            ])
    }

    @Test("URLRequest convenience defaults the method to GET")
    func urlRequestDefaultsToGET() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        var request = URLRequest(url: url)

        try await request.setNostrAuthorization(signer: signer)

        let value = try #require(request.value(forHTTPHeaderField: "Authorization"))
        let event = try HTTPAuth.validate(authorization: value, url: url, method: "GET")
        #expect(event.firstTagValue(named: "method") == "GET")
        #expect(event.firstTagValue(named: "payload") == nil)
    }

    @Test("URLRequest convenience rejects a request without a URL")
    func urlRequestWithoutURL() async throws {
        let signer = EventSigner(keyPair: KeyPair())
        var request = URLRequest(url: url)
        request.url = nil

        do {
            try await request.setNostrAuthorization(signer: signer)
            Issue.record("Expected HTTPAuth.AuthorizationError.missingURL")
        } catch {
            #expect(error as? HTTPAuth.AuthorizationError == .missingURL)
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
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
