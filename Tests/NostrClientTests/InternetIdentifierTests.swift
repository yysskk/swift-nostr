import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("InternetIdentifier Tests")
struct InternetIdentifierTests {

    // MARK: - Parsing Tests

    @Test("Parse standard identifier")
    func parseStandardIdentifier() {
        let identifier = InternetIdentifier("alice@example.com")

        #expect(identifier?.name == "alice")
        #expect(identifier?.domain == "example.com")
    }

    @Test("Parse underscore identifier")
    func parseUnderscoreIdentifier() {
        let identifier = InternetIdentifier("_@example.com")

        #expect(identifier?.name == "_")
        #expect(identifier?.domain == "example.com")
    }

    @Test("A bare domain is the domain's root identifier")
    func parseDomainOnly() {
        let identifier = InternetIdentifier("example.com")

        #expect(identifier?.name == "_")
        #expect(identifier?.domain == "example.com")
        #expect(identifier == InternetIdentifier("_@example.com"))
    }

    @Test("Parse identifier with subdomain")
    func parseSubdomain() {
        let identifier = InternetIdentifier("bob@nostr.example.com")

        #expect(identifier?.name == "bob")
        #expect(identifier?.domain == "nostr.example.com")
    }

    @Test("Parse empty string returns nil")
    func parseEmptyString() {
        #expect(InternetIdentifier("") == nil)
    }

    /// Splitting on the first `@` made this resolve against the host `domain@example.com`, which is
    /// not the domain a reader of the identifier would expect. NIP-05 allows only `a-z0-9-_.` in the
    /// local part, so an identifier carrying a second `@` is malformed however it is split.
    @Test("Parse identifier with multiple @ is rejected")
    func parseMultipleAt() {
        #expect(InternetIdentifier("user@domain@example.com") == nil)
    }

    @Test(
        "Parse rejects a local part outside the NIP-05 character set",
        arguments: ["al ice@example.com", "al/ice@example.com", "@example.com", "ali:ce@example.com"]
    )
    func parseRejectsInvalidLocalPart(identifier: String) {
        #expect(InternetIdentifier(identifier) == nil)
    }

    @Test(
        "Parse rejects a domain that could not be a URL host",
        arguments: ["alice@", "alice@exa mple.com", "alice@example.com/path", "alice@example.com:8080"]
    )
    func parseRejectsInvalidDomain(identifier: String) {
        #expect(InternetIdentifier(identifier) == nil)
    }

    @Test("Parse accepts the characters NIP-05 allows in a local part")
    func parseAcceptsAllowedLocalPart() {
        #expect(InternetIdentifier("a-b_c.d@example.com")?.name == "a-b_c.d")
        #expect(InternetIdentifier("Alice@example.com")?.name == "Alice")
        #expect(InternetIdentifier("bob123@example.com")?.name == "bob123")
    }

    @Test("the domain is lowercased and the name keeps its case")
    func domainIsLowercased() {
        let identifier = InternetIdentifier("Alice@Example.COM")

        #expect(identifier?.name == "Alice")
        #expect(identifier?.domain == "example.com")
        #expect(identifier == InternetIdentifier("Alice@example.com"))
        #expect(identifier != InternetIdentifier("alice@example.com"))
    }

    // MARK: - String Form Tests

    @Test(
        "description is name@domain",
        arguments: [
            ("alice@example.com", "alice@example.com"),
            ("_@example.com", "_@example.com"),
            ("example.com", "_@example.com"),
            ("Bob@Nostr.Example.com", "Bob@nostr.example.com"),
        ])
    func descriptionIsNameAtDomain(input: String, expected: String) {
        #expect(InternetIdentifier(input)?.description == expected)
    }

    @Test("description parses back to an equal identifier")
    func descriptionRoundTrips() throws {
        let identifier = try #require(InternetIdentifier("alice@example.com"))

        #expect(InternetIdentifier(identifier.description) == identifier)
    }

    @Test("encodes to and decodes from its string form")
    func codableRoundTrip() throws {
        let identifier = try #require(InternetIdentifier("alice@example.com"))

        let data = try JSONEncoder().encode(identifier)
        let decoded = try JSONDecoder().decode(InternetIdentifier.self, from: data)

        #expect(String(decoding: data, as: UTF8.self) == "\"alice@example.com\"")
        #expect(decoded == identifier)
    }

    @Test("decoding a malformed identifier throws")
    func decodingMalformedThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(InternetIdentifier.self, from: Data("\"user@domain@example.com\"".utf8))
        }
    }

    // MARK: - URL Construction Tests

    @Test(
        "the well-known URL queries the name on the domain",
        arguments: [
            ("alice@example.com", "https://example.com/.well-known/nostr.json?name=alice"),
            ("bob@nostr.example.com", "https://nostr.example.com/.well-known/nostr.json?name=bob"),
            ("example.com", "https://example.com/.well-known/nostr.json?name=_"),
        ])
    func wellKnownURL(input: String, expected: String) {
        #expect(InternetIdentifier(input)?.wellKnownURL.absoluteString == expected)
    }

    // MARK: - UserMetadata Tests

    @Test("UserMetadata exposes its nip05 as an identifier when well formed")
    func userMetadataInternetIdentifier() {
        #expect(UserMetadata(nip05: "alice@example.com").internetIdentifier == InternetIdentifier("alice@example.com"))
        #expect(UserMetadata(nip05: "user@domain@example.com").internetIdentifier == nil)
        #expect(UserMetadata().internetIdentifier == nil)
    }

    // MARK: - Verification Result Tests

    private let aliceIdentifier = InternetIdentifier("alice@example.com")!

    @Test("VerificationResult properties")
    func verificationResultProperties() {
        let result = InternetIdentifier.VerificationResult(
            identifier: aliceIdentifier,
            publicKey: .fixture("alice"),
            relays: [RelayURL("wss://relay1.com")!, RelayURL("wss://relay2.com")!]
        )

        #expect(result.identifier == aliceIdentifier)
        #expect(result.publicKey == .fixture("alice"))
        #expect(result.relays.count == 2)
    }

    @Test("VerificationResult equality")
    func verificationResultEquality() {
        let result1 = InternetIdentifier.VerificationResult(
            identifier: aliceIdentifier,
            publicKey: .fixture("alice"),
            relays: [RelayURL("wss://relay.com")!]
        )

        let result2 = InternetIdentifier.VerificationResult(
            identifier: aliceIdentifier,
            publicKey: .fixture("alice"),
            relays: [RelayURL("wss://relay.com")!]
        )

        let result3 = InternetIdentifier.VerificationResult(
            identifier: InternetIdentifier("bob@example.com")!,
            publicKey: .fixture("alice"),
            relays: [RelayURL("wss://relay.com")!]
        )

        #expect(result1 == result2)
        #expect(result1 != result3)
    }

    @Test("VerificationResult hashable")
    func verificationResultHashable() {
        let result1 = InternetIdentifier.VerificationResult(identifier: aliceIdentifier, publicKey: .fixture("alice"))
        let result2 = InternetIdentifier.VerificationResult(identifier: aliceIdentifier, publicKey: .fixture("alice"))

        let set: Set<InternetIdentifier.VerificationResult> = [result1, result2]

        #expect(set.count == 1)
    }

    // MARK: - Error Tests

    @Test("VerificationError descriptions")
    func verificationErrorDescriptions() {
        #expect(InternetIdentifier.VerificationError.networkError("offline").errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.invalidResponse.errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.publicKeyNotFound.errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.publicKeyMismatch.errorDescription != nil)
    }

    // MARK: - nostr.json Resolution Tests

    private let alice = PublicKey.fixture("alice")

    private func nostrJSON(names: [String: String], relays: [String: [String]]? = nil) throws -> Data {
        var object: [String: Any] = ["names": names]
        if let relays { object["relays"] = relays }
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("a canonical hex key resolves with the relays listed under it")
    func resolvesCanonicalKey() throws {
        let data = try nostrJSON(names: ["alice": alice.hex], relays: [alice.hex: ["wss://relay.example.com"]])

        let result = try InternetIdentifier("Alice@example.com")!.result(in: data)

        #expect(result.identifier == InternetIdentifier("Alice@example.com"))
        #expect(result.publicKey == alice)
        #expect(result.relays == [RelayURL("wss://relay.example.com")!])
    }

    @Test("relays listed under the key that are not relay URLs are skipped, the rest kept in order")
    func malformedRelaysAreSkipped() throws {
        let data = try nostrJSON(
            names: ["alice": alice.hex],
            relays: [
                alice.hex: ["https://web.example.com", "WSS://B.Example.com/", "not a relay", "wss://a.example.com"]
            ])

        let result = try aliceIdentifier.result(in: data)

        #expect(result.relays == [RelayURL("wss://b.example.com")!, RelayURL("wss://a.example.com")!])
    }

    @Test(
        "a names value that is not a canonical hex key is not found",
        arguments: ["abc123", "", "npub1notakey"])
    func malformedKeyIsNotFound(value: String) throws {
        let data = try nostrJSON(names: ["alice": value])

        #expect(throws: InternetIdentifier.VerificationError.publicKeyNotFound) {
            try aliceIdentifier.result(in: data)
        }
    }

    @Test("an uppercase hex key is not found")
    func uppercaseKeyIsNotFound() throws {
        let data = try nostrJSON(names: ["alice": alice.hex.uppercased()])

        #expect(throws: InternetIdentifier.VerificationError.publicKeyNotFound) {
            try aliceIdentifier.result(in: data)
        }
    }

    @Test("a missing name is not found")
    func missingNameIsNotFound() throws {
        let data = try nostrJSON(names: ["bob": alice.hex])

        #expect(throws: InternetIdentifier.VerificationError.publicKeyNotFound) {
            try aliceIdentifier.result(in: data)
        }
    }

    @Test("a document that is not nostr.json is an invalid response")
    func invalidDocumentIsInvalidResponse() {
        #expect(throws: InternetIdentifier.VerificationError.invalidResponse) {
            try aliceIdentifier.result(in: Data("[]".utf8))
        }
    }
}
