import Testing
import Foundation
@testable import NostrClient

@Suite("UserMetadata Tests")
struct UserMetadataTests {

    /// Realistic kind 0 content as relays deliver it (snake_case wire keys).
    private static let kind0JSON = """
    {
      "name": "alice",
      "display_name": "Alice In Nostrland",
      "about": "just here for the notes",
      "picture": "https://example.com/a.png",
      "banner": "https://example.com/b.png",
      "nip05": "alice@example.com",
      "website": "https://example.com",
      "lud06": "lnurl1dp68...",
      "lud16": "alice@walletofsatoshi.com"
    }
    """

    /// Regression guard for the fetchMetadata bug: a plain `JSONDecoder` (no
    /// `.convertFromSnakeCase`) must populate display_name, because UserMetadata
    /// declares `displayName = "display_name"` via explicit CodingKeys. Adding a
    /// snake_case strategy back would rewrite the key and decode displayName to nil.
    @Test("Plain decoder populates display_name and every snake_case field")
    func decodesSnakeCaseKeys() throws {
        let meta = try JSONDecoder().decode(UserMetadata.self, from: Data(Self.kind0JSON.utf8))

        #expect(meta.displayName == "Alice In Nostrland") // the field that used to be dropped
        #expect(meta.name == "alice")
        #expect(meta.about == "just here for the notes")
        #expect(meta.picture == "https://example.com/a.png")
        #expect(meta.banner == "https://example.com/b.png")
        #expect(meta.nip05 == "alice@example.com")
        #expect(meta.website == "https://example.com")
        #expect(meta.lud06 == "lnurl1dp68...")
        #expect(meta.lud16 == "alice@walletofsatoshi.com")
    }

    @Test("display_name without name still decodes displayName")
    func displayNameWithoutName() throws {
        let json = Data(#"{"display_name":"Bob"}"#.utf8)
        let meta = try JSONDecoder().decode(UserMetadata.self, from: json)

        #expect(meta.displayName == "Bob")
        #expect(meta.name == nil)
    }

    @Test("Encode emits display_name wire key and round-trips")
    func roundTripUsesSnakeCaseWireKey() throws {
        let original = UserMetadata(
            name: "alice",
            about: "bio",
            displayName: "Alice In Nostrland",
            website: "https://example.com",
            lud16: "alice@walletofsatoshi.com"
        )

        let data = try JSONEncoder().encode(original)
        let wire = String(decoding: data, as: UTF8.self)

        // The wire key must be snake_case (not the Swift property name).
        #expect(wire.contains("\"display_name\""))
        #expect(!wire.contains("\"displayName\""))

        let decoded = try JSONDecoder().decode(UserMetadata.self, from: data)
        #expect(decoded.displayName == "Alice In Nostrland")
        #expect(decoded.name == "alice")
        #expect(decoded.about == "bio")
        #expect(decoded.website == "https://example.com")
        #expect(decoded.lud16 == "alice@walletofsatoshi.com")
    }
}
