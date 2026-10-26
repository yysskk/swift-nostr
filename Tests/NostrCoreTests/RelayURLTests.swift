import Foundation
import Testing

@testable import NostrCore

@Suite("Relay URL Normalization Tests")
struct RelayURLNormalizationTests {

    @Test(
        "Normalizes to the canonical form",
        arguments: [
            ("wss://Relay.Example.COM", "wss://relay.example.com"),  // host case
            ("WSS://RELAY.EXAMPLE.COM", "wss://relay.example.com"),  // scheme case
            ("wss://relay.example.com/", "wss://relay.example.com"),  // root slash
            ("wss://relay.example.com", "wss://relay.example.com"),
            ("wss://relay.example.com:443", "wss://relay.example.com"),  // default wss port
            ("ws://relay.example.com:80", "ws://relay.example.com"),  // default ws port
            ("wss://relay.example.com:443/", "wss://relay.example.com"),
            ("wss://relay.example.com:7777", "wss://relay.example.com:7777"),
            ("ws://relay.example.com:443", "ws://relay.example.com:443"),  // the other scheme's default
            ("wss://Relay.EXAMPLE.com/NostrRelay", "wss://relay.example.com/NostrRelay"),  // path case kept
            ("wss://relay.example.com/a/", "wss://relay.example.com/a/"),  // non-root slash kept
            ("wss://relay.example.com/path?query=1", "wss://relay.example.com/path?query=1"),
        ])
    func normalizes(input: String, canonical: String) throws {
        let relayURL = try RelayURL(string: input)
        #expect(relayURL.description == canonical)
        #expect(relayURL.url == URL(string: canonical)!)
    }

    @Test("Normalization is idempotent")
    func idempotence() throws {
        for input in ["wss://Relay.Example.com/", "wss://relay.example.com:443/NostrRelay", "ws://HOST:80/a/"] {
            let once = try RelayURL(string: input)
            #expect(try RelayURL(string: once.description).description == once.description)
        }
    }

    @Test("A non-root trailing slash keeps two paths distinct")
    func nonRootSlashIsSignificant() throws {
        #expect(try RelayURL(string: "wss://host/a/") != RelayURL(string: "wss://host/a"))
    }

    @Test("Path case is significant")
    func pathCaseIsSignificant() throws {
        #expect(try RelayURL(string: "wss://host/Relay") != RelayURL(string: "wss://host/relay"))
    }
}

@Suite("Relay URL Validation Tests")
struct RelayURLValidationTests {

    @Test(
        "Rejects strings that are not WebSocket relay URLs, naming the reason",
        arguments: [
            ("https://relay.example.com", RelayURL.Error.unsupportedScheme("https")),
            ("http://relay.example.com", .unsupportedScheme("http")),
            ("HTTP://relay.example.com", .unsupportedScheme("http")),
            ("relay.example.com", .malformed),  // no scheme
            ("wss:garbage", .missingHost),
            ("wss://", .missingHost),  // empty host
            ("wss://relay.example.com/path#frag", .containsFragment),
            ("wss://user:pw@relay.example.com", .containsCredentials),
            ("wss://user@relay.example.com", .containsCredentials),
            ("not a url", .malformed),  // unparseable
            ("", .malformed),
        ])
    func rejects(input: String, expected: RelayURL.Error) {
        #expect(throws: expected) {
            _ = try RelayURL(string: input)
        }
        #expect(RelayURL(input) == nil)
    }

    @Test("init(url:) validates and normalizes, reporting why a URL is rejected")
    func initFromURL() throws {
        #expect(try RelayURL(url: URL(string: "wss://Relay.Example.com:443/")!) == RelayURL("wss://relay.example.com"))
        let https = URL(string: "https://relay.example.com")!
        #expect(throws: RelayURL.Error.unsupportedScheme("https")) {
            _ = try RelayURL(url: https)
        }
    }
}

@Suite("Relay URL Value Semantics Tests")
struct RelayURLValueSemanticsTests {

    @Test("Equivalent spellings are equal and hash alike")
    func equivalentSpellings() throws {
        let spellings = [
            "wss://relay.example.com",
            "wss://Relay.Example.com/",
            "WSS://RELAY.EXAMPLE.COM:443",
            "wss://relay.example.com:443/",
        ]
        let urls = try spellings.map { try RelayURL(string: $0) }
        #expect(Set(urls).count == 1)
        for url in urls {
            #expect(url == urls[0])
            #expect(url.hashValue == urls[0].hashValue)
        }
        let dictionary = [urls[0]: "first"]
        #expect(dictionary[try RelayURL(string: "wss://RELAY.example.com/")] == "first")
    }

    @Test("Distinct relays are not equal")
    func distinctRelays() throws {
        #expect(try RelayURL(string: "wss://relay.example.com") != RelayURL(string: "ws://relay.example.com"))
        #expect(try RelayURL(string: "wss://relay.example.com") != RelayURL(string: "wss://relay.example.com:7777"))
        #expect(try RelayURL(string: "wss://a.example.com") != RelayURL(string: "wss://b.example.com"))
    }

    @Test("LosslessStringConvertible round-trips through the canonical description")
    func losslessStringConvertible() throws {
        let relayURL = try #require(RelayURL("WSS://Relay.Example.com/nostr"))
        #expect(relayURL.description == "wss://relay.example.com/nostr")
        #expect(String(describing: relayURL) == "wss://relay.example.com/nostr")
        #expect(RelayURL(relayURL.description) == relayURL)
    }

    @Test("Encodes as its canonical string and decodes any valid spelling")
    func codable() throws {
        let relayURL = try RelayURL(string: "wss://Relay.Example.com/")
        let encoded = try JSONEncoder().encode([relayURL])
        #expect(String(decoding: encoded, as: UTF8.self) == #"["wss:\/\/relay.example.com"]"#)

        let decoded = try JSONDecoder().decode([RelayURL].self, from: Data(#"["WSS://relay.example.com:443"]"#.utf8))
        #expect(decoded == [relayURL])
    }

    @Test("Decoding an invalid relay URL fails with dataCorrupted")
    func decodingInvalidFails() {
        for json in [#"["https://relay.example.com"]"#, #"["wss://"]"#, #"[""]"#] {
            #expect {
                _ = try JSONDecoder().decode([RelayURL].self, from: Data(json.utf8))
            } throws: { error in
                guard case DecodingError.dataCorrupted = error else { return false }
                return true
            }
        }
    }
}
