import Foundation
import NostrCore
import Testing

/// Filters are only correct if the keys reach the relay exactly as NIP-01 spells them. A relay
/// silently ignores a tag-query key it does not recognize and answers the rest of the filter, so a
/// mangled key is not an error the caller can see — it is a wider result set than was asked for.
@Suite("Filter Wire Serialization Tests")
struct FilterSerializationTests {
    private func serializedFilter(_ filter: Filter) throws -> [String: Any] {
        let json = try ClientMessage.request(subscriptionId: "sub", filters: [filter]).serialize()
        let array = try #require(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any]
        )
        return try #require(array.last as? [String: Any])
    }

    /// NIP-01 indexes single-letter tags `a-zA-Z`, and NIP-22 uses the uppercase letters for
    /// root-scope tags (`A`, `E`, `I`, `K`, `P`). Encoding these through a key strategy that
    /// inserts a separator before each capital turned `#K` into `#_k`.
    @Test(
        "uppercase tag queries keep their NIP-01 spelling",
        arguments: ["A", "E", "I", "K", "P"]
    )
    func uppercaseTagQueryIsPreserved(letter: String) throws {
        var filter = Filter(kinds: [1111])
        filter.addTagQuery(letter, values: ["30023"])

        let dictionary = try serializedFilter(filter)

        #expect(dictionary["#\(letter)"] as? [String] == ["30023"])
        #expect(dictionary["#_\(letter.lowercased())"] == nil)
    }

    @Test("lowercase tag queries are unchanged")
    func lowercaseTagQueryIsPreserved() throws {
        var filter = Filter(kinds: [1])
        filter.addTagQuery("t", values: ["nostr"])

        let dictionary = try serializedFilter(filter)

        #expect(dictionary["#t"] as? [String] == ["nostr"])
    }

    @Test("mixed-case tag queries survive alongside each other")
    func mixedCaseTagQueriesCoexist() throws {
        var filter = Filter(kinds: [1111])
        filter.addTagQuery("K", values: ["30023"])
        filter.addTagQuery("k", values: ["1"])

        let dictionary = try serializedFilter(filter)

        #expect(dictionary["#K"] as? [String] == ["30023"])
        #expect(dictionary["#k"] as? [String] == ["1"])
    }

    /// The declared keys already carry their wire spelling, so removing the key strategy must not
    /// disturb them — `created_at` in particular is not derived from the property name.
    @Test("declared filter keys keep their wire spelling")
    func declaredKeysAreUnchanged() throws {
        let now = Int64(1_700_000_000)
        let filter = Filter(
            ids: ["aa"],
            authors: ["bb"],
            kinds: [1],
            eventReferences: ["cc"],
            pubkeyReferences: ["dd"],
            since: now,
            until: now + 60,
            limit: 10
        )

        let dictionary = try serializedFilter(filter)

        #expect(dictionary["ids"] as? [String] == ["aa"])
        #expect(dictionary["authors"] as? [String] == ["bb"])
        #expect(dictionary["kinds"] as? [Int] == [1])
        #expect(dictionary["#e"] as? [String] == ["cc"])
        #expect(dictionary["#p"] as? [String] == ["dd"])
        #expect(dictionary["since"] as? Int64 == now)
        #expect(dictionary["until"] as? Int64 == now + 60)
        #expect(dictionary["limit"] as? Int == 10)
    }

    /// COUNT carries the same filter payload as REQ (NIP-45), so it must not diverge.
    @Test("count messages serialize tag queries identically")
    func countMessageMatchesRequest() throws {
        var filter = Filter(kinds: [1111])
        filter.addTagQuery("K", values: ["30023"])

        let json = try ClientMessage.count(subscriptionId: "sub", filters: [filter]).serialize()
        let array = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        let dictionary = try #require(array.last as? [String: Any])

        #expect(dictionary["#K"] as? [String] == ["30023"])
    }

    /// An event on the wire keeps `created_at`; the same encoder serializes it.
    @Test("events serialize created_at in snake case")
    func eventKeepsCreatedAt() throws {
        let signer = try EventSigner(
            privateKeyHex: "5566778899aabbccddeeff00112233445566778899aabbccddeeff0011223344"
        )
        let event = try signer.signTextNote(content: "gm")

        let json = try ClientMessage.event(event).serialize()
        let array = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [Any])
        let dictionary = try #require(array.last as? [String: Any])

        #expect(dictionary["created_at"] as? Int64 == event.createdAt)
        #expect(dictionary["createdAt"] == nil)
    }
}
