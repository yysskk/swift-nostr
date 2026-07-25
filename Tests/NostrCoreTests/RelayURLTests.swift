import Foundation
import Testing

@testable import NostrCore

@Suite("Relay URL Normalization Tests")
struct RelayURLTests {

    @Test("Lowercases the scheme and host")
    func lowercases() {
        #expect(RelayURL.normalize("wss://Relay.Example.COM") == "wss://relay.example.com")
        #expect(RelayURL.normalize("WSS://RELAY.EXAMPLE.COM") == "wss://relay.example.com")
    }

    @Test("Preserves path case")
    func preservesPathCase() {
        #expect(RelayURL.normalize("wss://Relay.EXAMPLE.com/NostrRelay") == "wss://relay.example.com/NostrRelay")
    }

    @Test("Strips the root trailing slash")
    func stripsTrailingSlash() {
        #expect(RelayURL.normalize("wss://relay.example.com/") == "wss://relay.example.com")
    }

    @Test("Preserves a non-root trailing slash")
    func preservesNonRootTrailingSlash() {
        #expect(RelayURL.normalize("wss://host/a/") == "wss://host/a/")
    }

    @Test("Leaves a URL without a trailing slash unchanged")
    func noTrailingSlash() {
        #expect(RelayURL.normalize("wss://relay.example.com") == "wss://relay.example.com")
    }

    @Test("Strips default ports")
    func stripsDefaultPorts() {
        #expect(RelayURL.normalize("wss://host:443") == "wss://host")
        #expect(RelayURL.normalize("ws://host:80") == "ws://host")
    }

    @Test("Preserves non-default ports")
    func preservesNonDefaultPorts() {
        #expect(RelayURL.normalize("wss://host:7777") == "wss://host:7777")
        // A port that is only a default for the *other* scheme is not a default here.
        #expect(RelayURL.normalize("ws://host:443") == "ws://host:443")
    }

    @Test("Unparseable input falls back to the whole-string rule")
    func unparseableFallsBack() {
        #expect(RelayURL.normalize("Not A URL/") == "not a url")
        #expect(RelayURL.normalize("Not A URL") == "not a url")
    }

    @Test("Normalization is idempotent")
    func idempotence() {
        let inputs = [
            "wss://Relay.Example.com/",
            "wss://relay.example.com:443/NostrRelay",
            "ws://HOST:80/a/",
            "Not A URL/",
        ]
        for input in inputs {
            let once = RelayURL.normalize(input)
            #expect(RelayURL.normalize(once) == once)
        }
    }

    @Test("normalizedURL round-trips strings and URLs to the canonical key")
    func normalizedURLRoundTrips() {
        let canonical = URL(string: "wss://relay.example.com")!
        #expect(RelayURL.normalizedURL("wss://Relay.Example.com/") == canonical)
        #expect(RelayURL.normalizedURL(URL(string: "wss://Relay.Example.com/")!) == canonical)
        #expect(RelayURL.normalizedURL(URL(string: "wss://relay.example.com:443")!) == canonical)
        #expect(RelayURL.normalizedURL(canonical) == canonical)
    }
}

@Suite("Relay URL Target Validation Tests")
struct RelayURLTargetValidationTests {

    @Test(
        "requireTarget accepts WebSocket relay URLs and returns the canonical key",
        arguments: [
            ("wss://relay.example.com", "wss://relay.example.com"),
            ("WSS://Relay.Example.COM/", "wss://relay.example.com"),
            ("ws://relay.example.com", "ws://relay.example.com"),
            ("wss://relay.example.com:7777", "wss://relay.example.com:7777"),
            ("wss://relay.example.com:443/NostrRelay", "wss://relay.example.com/NostrRelay"),
            ("wss://relay.example.com/path?query=1", "wss://relay.example.com/path?query=1"),
        ])
    func requireTargetAccepts(input: String, canonical: String) throws {
        #expect(try RelayURL.requireTarget(input) == URL(string: canonical)!)
    }

    @Test(
        "requireTarget rejects non-relay URLs",
        arguments: [
            "https://relay.example.com",  // non-WebSocket scheme
            "http://relay.example.com",
            "wss:garbage",  // no host
            "wss://",  // empty host
            "wss://relay.example.com/path#frag",  // fragment
            "wss://user:pw@relay.example.com",  // userinfo
            "wss://user@relay.example.com",
            "not a url",
            "",
        ])
    func requireTargetRejects(input: String) {
        #expect(throws: NostrError.invalidRelayURL(input)) {
            _ = try RelayURL.requireTarget(input)
        }
    }

    @Test("requireTargets de-duplicates by canonical key and throws on the first offender")
    func requireTargetsDeduplicatesAndThrows() throws {
        let targets = try RelayURL.requireTargets([
            "wss://relay.example.com",
            "wss://Relay.Example.com/",
            "wss://other.example.com",
        ])
        #expect(
            targets == [
                URL(string: "wss://relay.example.com")!,
                URL(string: "wss://other.example.com")!,
            ]
        )

        #expect(throws: NostrError.invalidRelayURL("https://not-a-relay.example.com")) {
            _ = try RelayURL.requireTargets(["wss://relay.example.com", "https://not-a-relay.example.com"])
        }
    }

    @Test("urlSet keeps valid relay URLs and skips garbage entries")
    func urlSetSkipsInvalidEntries() {
        let urls = RelayURL.urlSet([
            "wss://relay.example.com",
            "wss://Relay.Example.com/",  // duplicate after normalization
            "https://not-a-relay.example.com",  // wrong scheme
            "wss:garbage",  // no host
            "wss://r.example.com/path#frag",  // fragment
            "ws://second.example.com",
        ])
        #expect(
            urls == [
                URL(string: "wss://relay.example.com")!,
                URL(string: "ws://second.example.com")!,
            ]
        )
    }
}
