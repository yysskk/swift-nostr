import Crypto
import Foundation
import NostrCore
import Testing

@Suite("HTTP Auth Validation Tests")
struct HTTPAuthValidationTests {
    let url = URL(string: "https://api.example.com/upload?type=media")!

    /// Signs a request into a header value at a fixed timestamp and returns
    /// both, so tests validate against a pinned clock.
    func signedHeader(
        method: String = "GET",
        payload: Data? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) async throws -> (header: String, now: Date, signer: EventSigner) {
        let signer = EventSigner(keyPair: try KeyPair())
        let header = try await HTTPAuth.authorizationHeaderValue(
            url: url, method: method, payload: payload, createdAt: createdAt, signer: signer)
        return (header, createdAt, signer)
    }

    /// Encodes an arbitrary event as a header value, bypassing the
    /// kind check of `authorizationHeaderValue(for:)`.
    func rawHeader(for event: Event) throws -> String {
        "Nostr " + (try JSONEncoder().encode(event)).base64EncodedString()
    }

    // MARK: Happy Paths

    @Test("a signed GET round-trips through validation")
    func getRoundTrip() async throws {
        let (header, now, signer) = try await signedHeader()

        let event = try HTTPAuth.validate(
            authorization: header, url: url, method: "GET", now: now)

        #expect(event.pubkey == signer.publicKey)
        #expect(event.kind == .httpAuth)
    }

    @Test("a signed POST with a body round-trips through validation")
    func postRoundTrip() async throws {
        let body = Data("{\"name\":\"nostr\"}".utf8)
        let (header, now, signer) = try await signedHeader(method: "POST", payload: body)

        let event = try HTTPAuth.validate(
            authorization: header, url: url, method: "POST", payload: body, now: now)

        #expect(event.pubkey == signer.publicKey)
    }

    @Test("the NIP-98 spec example header decodes, and its inconsistent signature is rejected")
    func specVectorDecodes() throws {
        // The example credential from the NIP-98 specification: a kind-27235
        // event authorizing GET https://api.snort.social/api/v1/n5sp/list at
        // created_at 1682327852, in unpadded base64 as published.
        // https://github.com/nostr-protocol/nips/blob/master/98.md
        let header =
            "Nostr eyJpZCI6ImZlOTY0ZTc1ODkwMzM2MGYyOGQ4NDI0ZDA5MmRhODQ5NGVkMjA3Y2JhODIzMTEwYmUzYTU3ZGZlNGI1Nzg3MzQiLCJwdWJrZXkiOiI2M2ZlNjMxOGRjNTg1ODNjZmUxNjgxMGY4NmRkMDllMThiZmQ3NmFhYmMyNGEwMDgxY2UyODU2ZjMzMDUwNGVkIiwiY29udGVudCI6IiIsImtpbmQiOjI3MjM1LCJjcmVhdGVkX2F0IjoxNjgyMzI3ODUyLCJ0YWdzIjpbWyJ1IiwiaHR0cHM6Ly9hcGkuc25vcnQuc29jaWFsL2FwaS92MS9uNXNwL2xpc3QiXSxbIm1ldGhvZCIsIkdFVCJdXSwic2lnIjoiNWVkOWQ4ZWM5NThiYzg1NGY5OTdiZGMyNGFjMzM3ZDAwNWFmMzcyMzI0NzQ3ZWZlNGEwMGUyNGY0YzMwNDM3ZmY0ZGQ4MzA4Njg0YmVkNDY3ZDlkNmJlM2U1YTUxN2JiNDNiMTczMmNjN2QzMzk0OWEzYWFmODY3MDVjMjIxODQifQ"

        // The wire format decodes into the exact event fields.
        let event = try HTTPAuth.event(fromAuthorizationHeader: header)
        #expect(event.kind == .httpAuth)
        #expect(event.pubkey == "63fe6318dc58583cfe16810f86dd09e18bfd76aabc24a0081ce2856f330504ed")
        #expect(event.id == "fe964e758903360f28d8424d092da8494ed207cba823110be3a57dfe4b578734")
        #expect(event.createdAt == 1_682_327_852)
        #expect(event.firstTagValue(named: "u") == "https://api.snort.social/api/v1/n5sp/list")
        #expect(event.firstTagValue(named: "method") == "GET")

        // The published example is illustrative, not consistently signed: its
        // id does not match its NIP-01 serialization, so full validation must
        // reject it rather than wave it through.
        #expect(throws: HTTPAuth.ValidationError.invalidSignature) {
            try HTTPAuth.validate(
                authorization: header,
                url: URL(string: "https://api.snort.social/api/v1/n5sp/list")!,
                method: "GET",
                now: Date(timeIntervalSince1970: 1_682_327_852)
            )
        }
    }

    @Test("the scheme is matched case-insensitively")
    func schemeCaseInsensitive() async throws {
        let (header, now, _) = try await signedHeader()
        let lowercased = "nostr" + header.dropFirst("Nostr".count)

        #expect(throws: Never.self) {
            try HTTPAuth.validate(authorization: lowercased, url: url, method: "GET", now: now)
        }
    }

    @Test("the request method is matched case-insensitively")
    func methodCaseInsensitive() async throws {
        let (header, now, _) = try await signedHeader()

        #expect(throws: Never.self) {
            try HTTPAuth.validate(authorization: header, url: url, method: "get", now: now)
        }
    }

    @Test("unpadded base64 is accepted")
    func unpaddedBase64() async throws {
        let (header, now, _) = try await signedHeader()
        let unpadded = header.replacingOccurrences(of: "=", with: "")

        #expect(throws: Never.self) {
            try HTTPAuth.validate(authorization: unpadded, url: url, method: "GET", now: now)
        }
    }

    @Test("without a payload argument, a payload tag is not checked")
    func payloadCheckSkippedWhenNil() async throws {
        let (header, now, _) = try await signedHeader(method: "POST", payload: Data("body".utf8))

        // Validating without the body skips the payload comparison.
        #expect(throws: Never.self) {
            try HTTPAuth.validate(authorization: header, url: url, method: "POST", now: now)
        }
    }

    // MARK: Failure Paths

    @Test("a non-Nostr scheme is rejected")
    func wrongScheme() {
        #expect(throws: HTTPAuth.ValidationError.invalidAuthorizationScheme) {
            try HTTPAuth.validate(authorization: "Bearer abc123", url: url, method: "GET")
        }
        #expect(throws: HTTPAuth.ValidationError.invalidAuthorizationScheme) {
            try HTTPAuth.validate(authorization: "", url: url, method: "GET")
        }
        #expect(throws: HTTPAuth.ValidationError.invalidAuthorizationScheme) {
            try HTTPAuth.validate(authorization: "Nostr", url: url, method: "GET")
        }
    }

    @Test("invalid base64 is rejected")
    func invalidBase64() {
        #expect(throws: HTTPAuth.ValidationError.invalidBase64) {
            try HTTPAuth.validate(authorization: "Nostr not-base64!!", url: url, method: "GET")
        }
    }

    @Test("base64 that is not an event is rejected")
    func malformedEvent() {
        let notAnEvent = Data("{\"hello\":\"world\"}".utf8).base64EncodedString()

        #expect(throws: HTTPAuth.ValidationError.malformedEvent) {
            try HTTPAuth.validate(authorization: "Nostr \(notAnEvent)", url: url, method: "GET")
        }
    }

    @Test("an event of the wrong kind is rejected")
    func wrongKind() async throws {
        let signer = EventSigner(keyPair: try KeyPair())
        let note = try signer.sign(
            UnsignedEvent(pubkey: signer.publicKey, kind: .textNote, content: ""))

        #expect(throws: HTTPAuth.ValidationError.invalidEventKind(.textNote)) {
            try HTTPAuth.validate(
                authorization: try rawHeader(for: note), url: url, method: "GET")
        }
    }

    @Test("a tampered event is rejected")
    func tamperedEvent() async throws {
        let (header, now, _) = try await signedHeader()
        let original = try HTTPAuth.event(fromAuthorizationHeader: header)
        // Re-target the signed event at a different URL without re-signing.
        let tampered = Event(
            id: original.id,
            pubkey: original.pubkey,
            createdAt: original.createdAt,
            kind: original.kind,
            tags: [["u", "https://evil.example.com/"], ["method", "GET"]],
            content: original.content,
            sig: original.sig
        )

        #expect(throws: HTTPAuth.ValidationError.invalidSignature) {
            try HTTPAuth.validate(
                authorization: try rawHeader(for: tampered),
                url: URL(string: "https://evil.example.com/")!,
                method: "GET",
                now: now
            )
        }
    }

    @Test("a timestamp outside the tolerance is rejected, at the boundary it passes")
    func timestampTolerance() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let (header, _, _) = try await signedHeader(createdAt: createdAt)

        // Exactly at the tolerance edge, in both directions: accepted.
        #expect(throws: Never.self) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "GET",
                now: createdAt.addingTimeInterval(60))
        }
        #expect(throws: Never.self) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "GET",
                now: createdAt.addingTimeInterval(-60))
        }
        // One second past the tolerance, in both directions: rejected.
        #expect(throws: HTTPAuth.ValidationError.timestampOutOfTolerance(createdAt: createdAt)) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "GET",
                now: createdAt.addingTimeInterval(61))
        }
        #expect(throws: HTTPAuth.ValidationError.timestampOutOfTolerance(createdAt: createdAt)) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "GET",
                now: createdAt.addingTimeInterval(-61))
        }
    }

    @Test("a custom tolerance widens the accepted window")
    func customTolerance() async throws {
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let (header, _, _) = try await signedHeader(createdAt: createdAt)

        #expect(throws: Never.self) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "GET",
                tolerance: 300, now: createdAt.addingTimeInterval(200))
        }
    }

    @Test("a URL mismatch is rejected, including a query difference")
    func urlMismatch() async throws {
        let (header, now, _) = try await signedHeader()
        let otherURL = URL(string: "https://api.example.com/upload?type=other")!

        #expect(
            throws: HTTPAuth.ValidationError.urlMismatch(
                expected: otherURL.absoluteString, actual: url.absoluteString)
        ) {
            try HTTPAuth.validate(authorization: header, url: otherURL, method: "GET", now: now)
        }
    }

    @Test("a method mismatch is rejected")
    func methodMismatch() async throws {
        let (header, now, _) = try await signedHeader(method: "GET")

        #expect(throws: HTTPAuth.ValidationError.methodMismatch(expected: "POST", actual: "GET")) {
            try HTTPAuth.validate(authorization: header, url: url, method: "POST", now: now)
        }
    }

    @Test("a payload hash mismatch and a missing payload tag are rejected")
    func payloadMismatch() async throws {
        let signedBody = Data("signed body".utf8)
        let receivedBody = Data("different body".utf8)
        let expectedHash = Data(SHA256.hash(data: receivedBody)).hexEncodedString()
        let signedHash = Data(SHA256.hash(data: signedBody)).hexEncodedString()

        let (header, now, _) = try await signedHeader(method: "POST", payload: signedBody)
        #expect(
            throws: HTTPAuth.ValidationError.payloadHashMismatch(
                expected: expectedHash, actual: signedHash)
        ) {
            try HTTPAuth.validate(
                authorization: header, url: url, method: "POST", payload: receivedBody, now: now)
        }

        let (noPayloadHeader, sameNow, _) = try await signedHeader(method: "POST")
        #expect(
            throws: HTTPAuth.ValidationError.payloadHashMismatch(
                expected: expectedHash, actual: nil)
        ) {
            try HTTPAuth.validate(
                authorization: noPayloadHeader, url: url, method: "POST",
                payload: receivedBody, now: sameNow)
        }
    }

    // MARK: Header Decoding

    @Test("event(fromAuthorizationHeader:) decodes without validating")
    func decodeWithoutValidation() async throws {
        let (header, _, signer) = try await signedHeader()

        // Succeeds even though the event is long expired against the real clock.
        let event = try HTTPAuth.event(fromAuthorizationHeader: header)

        #expect(event.pubkey == signer.publicKey)
        #expect(event.firstTagValue(named: "u") == url.absoluteString)
    }
}
