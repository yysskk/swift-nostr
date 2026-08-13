import Foundation
import Testing

@testable import NostrClient

@Suite("InternetIdentifier Tests")
struct InternetIdentifierTests {

    // MARK: - Parsing Tests

    @Test("Parse standard identifier")
    func parseStandardIdentifier() {
        let result = InternetIdentifier.parse("alice@example.com")

        #expect(result?.name == "alice")
        #expect(result?.domain == "example.com")
    }

    @Test("Parse underscore identifier")
    func parseUnderscoreIdentifier() {
        let result = InternetIdentifier.parse("_@example.com")

        #expect(result?.name == "_")
        #expect(result?.domain == "example.com")
    }

    @Test("Parse domain only")
    func parseDomainOnly() {
        let result = InternetIdentifier.parse("example.com")

        #expect(result?.name == "_")
        #expect(result?.domain == "example.com")
    }

    @Test("Parse identifier with subdomain")
    func parseSubdomain() {
        let result = InternetIdentifier.parse("bob@nostr.example.com")

        #expect(result?.name == "bob")
        #expect(result?.domain == "nostr.example.com")
    }

    @Test("Parse empty string returns nil")
    func parseEmptyString() {
        let result = InternetIdentifier.parse("")

        #expect(result == nil)
    }

    /// Splitting on the first `@` made this resolve against the host `domain@example.com`, which is
    /// not the domain a reader of the identifier would expect. NIP-05 allows only `a-z0-9-_.` in the
    /// local part, so an identifier carrying a second `@` is malformed however it is split.
    @Test("Parse identifier with multiple @ is rejected")
    func parseMultipleAt() {
        #expect(InternetIdentifier.parse("user@domain@example.com") == nil)
        #expect(!"user@domain@example.com".isValidInternetIdentifier)
    }

    @Test(
        "Parse rejects a local part outside the NIP-05 character set",
        arguments: ["al ice@example.com", "al/ice@example.com", "@example.com", "ali:ce@example.com"]
    )
    func parseRejectsInvalidLocalPart(identifier: String) {
        #expect(InternetIdentifier.parse(identifier) == nil)
    }

    @Test(
        "Parse rejects a domain that could not be a URL host",
        arguments: ["alice@", "alice@exa mple.com", "alice@example.com/path", "alice@example.com:8080"]
    )
    func parseRejectsInvalidDomain(identifier: String) {
        #expect(InternetIdentifier.parse(identifier) == nil)
    }

    @Test("Parse accepts the characters NIP-05 allows in a local part")
    func parseAcceptsAllowedLocalPart() {
        #expect(InternetIdentifier.parse("a-b_c.d@example.com")?.name == "a-b_c.d")
        #expect(InternetIdentifier.parse("Alice@example.com")?.name == "Alice")
        #expect(InternetIdentifier.parse("bob123@example.com")?.name == "bob123")
    }

    // MARK: - URL Construction Tests

    @Test("Construct well-known URL")
    func constructWellKnownURL() {
        let url = InternetIdentifier.wellKnownURL(name: "alice", domain: "example.com")

        #expect(url?.absoluteString == "https://example.com/.well-known/nostr.json?name=alice")
    }

    @Test("Construct well-known URL with subdomain")
    func constructWellKnownURLWithSubdomain() {
        let url = InternetIdentifier.wellKnownURL(name: "bob", domain: "nostr.example.com")

        #expect(url?.absoluteString == "https://nostr.example.com/.well-known/nostr.json?name=bob")
    }

    @Test("Construct well-known URL with underscore")
    func constructWellKnownURLWithUnderscore() {
        let url = InternetIdentifier.wellKnownURL(name: "_", domain: "example.com")

        #expect(url?.absoluteString == "https://example.com/.well-known/nostr.json?name=_")
    }

    // MARK: - String Extension Tests

    @Test("String isValidInternetIdentifier with valid identifier")
    func stringIsValidInternetIdentifierValid() {
        #expect("alice@example.com".isValidInternetIdentifier)
        #expect("_@example.com".isValidInternetIdentifier)
        #expect("example.com".isValidInternetIdentifier)
    }

    @Test("String isValidInternetIdentifier with empty string")
    func stringIsValidInternetIdentifierEmpty() {
        #expect(!"".isValidInternetIdentifier)
    }

    // MARK: - Verification Result Tests

    @Test("VerificationResult properties")
    func verificationResultProperties() {
        let result = InternetIdentifier.VerificationResult(
            identifier: "alice@example.com",
            pubkey: "abc123",
            relays: ["wss://relay1.com", "wss://relay2.com"]
        )

        #expect(result.identifier == "alice@example.com")
        #expect(result.pubkey == "abc123")
        #expect(result.relays.count == 2)
    }

    @Test("VerificationResult equality")
    func verificationResultEquality() {
        let result1 = InternetIdentifier.VerificationResult(
            identifier: "alice@example.com",
            pubkey: "abc123",
            relays: ["wss://relay.com"]
        )

        let result2 = InternetIdentifier.VerificationResult(
            identifier: "alice@example.com",
            pubkey: "abc123",
            relays: ["wss://relay.com"]
        )

        let result3 = InternetIdentifier.VerificationResult(
            identifier: "bob@example.com",
            pubkey: "abc123",
            relays: ["wss://relay.com"]
        )

        #expect(result1 == result2)
        #expect(result1 != result3)
    }

    @Test("VerificationResult hashable")
    func verificationResultHashable() {
        let result1 = InternetIdentifier.VerificationResult(
            identifier: "alice@example.com",
            pubkey: "abc123"
        )

        let result2 = InternetIdentifier.VerificationResult(
            identifier: "alice@example.com",
            pubkey: "abc123"
        )

        var set: Set<InternetIdentifier.VerificationResult> = []
        set.insert(result1)
        set.insert(result2)

        #expect(set.count == 1)
    }

    // MARK: - Error Tests

    @Test("VerificationError descriptions")
    func verificationErrorDescriptions() {
        #expect(InternetIdentifier.VerificationError.invalidIdentifier.errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.invalidResponse.errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.pubkeyNotFound.errorDescription != nil)
        #expect(InternetIdentifier.VerificationError.pubkeyMismatch.errorDescription != nil)
    }

    // MARK: - Integration Tests (require network)

    @Test("Verify invalid identifier format throws error")
    func verifyInvalidIdentifierFormat() async {
        do {
            _ = try await InternetIdentifier.verify("")
            Issue.record("Expected error to be thrown")
        } catch let error as InternetIdentifier.VerificationError {
            if case .invalidIdentifier = error {
                // Expected error
            } else {
                Issue.record("Unexpected VerificationError type: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}
