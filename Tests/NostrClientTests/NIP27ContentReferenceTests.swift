import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-27 Content Reference Tests")
struct NIP27ContentReferenceTests {
    // Canonical NIP-19 spec vectors, reused from the NIP-19/NIP-21 suites.
    let pubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let eventIdHex = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"
    let npubVector = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    let npubPubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let noteVector = "note1fntxtkcy9pjwucqwa9mddn7v03wwwsu9j330jj350nvhpky2tuaspk6nqc"
    let noteIdHex = "4cd665db042864ee600ee976d6cfcc7c5ce743859462f94a347cd970d88a5f3b"

    // MARK: - references(in:)

    @Test("a single npub reference is found with an accurate range and entity")
    func singleNpubReference() throws {
        let content = "gm nostr:\(npubVector)"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 1)

        let reference = try #require(references.first)
        #expect(reference.text == "nostr:\(npubVector)")
        // The native String.Index range slices back to exactly the matched text.
        #expect(String(content[reference.range]) == reference.text)
        #expect(reference.entity == .npub(npubPubkeyHex))
    }

    @Test("multiple references are returned in order of appearance")
    func multipleReferencesInOrder() {
        let content = "see nostr:\(npubVector) and nostr:\(noteVector) today"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 2)
        #expect(references[0].entity == .npub(npubPubkeyHex))
        #expect(references[1].entity == .note(noteIdHex))
    }

    @Test("trailing punctuation is excluded from the match")
    func trailingPunctuationExcluded() {
        let content = "wow nostr:\(noteVector)!"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 1)
        #expect(references[0].text == "nostr:\(noteVector)")
        #expect(references[0].entity == .note(noteIdHex))
    }

    @Test("a letter before the scheme is not a word boundary and is not matched")
    func wordBoundaryRequiredBeforeScheme() {
        let content = "xnostr:\(npubVector)"
        #expect(NostrContentReference.references(in: content).isEmpty)
    }

    @Test("an nsec reference is skipped")
    func nsecReferenceSkipped() throws {
        // Source a valid nsec bech32 by encoding a 32-byte key through the existing API.
        let nsecBech32 = try NIP19Entity.nsec(pubkeyHex).encoded
        let content = "leaked nostr:\(nsecBech32) oops"
        #expect(NostrContentReference.references(in: content).isEmpty)
    }

    @Test("an undecodable bech32 token is skipped")
    func undecodableTokenSkipped() {
        #expect(NostrContentReference.references(in: "nostr:notarealthing").isEmpty)
    }

    @Test("references are located by native String.Index in multi-scalar content")
    func multiScalarContentRange() throws {
        let content = "👨‍👩‍👧‍👦 nostr:\(npubVector) end"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 1)
        let reference = try #require(references.first)
        #expect(String(content[reference.range]) == reference.text)
    }

    // MARK: - tag mapping

    @Test("an npub maps to a p tag")
    func npubMapsToPubkeyTag() {
        let content = "nostr:\(npubVector)"
        let reference = NostrContentReference.references(in: content).first
        #expect(reference?.tag.rawArray == ["p", npubPubkeyHex])
    }

    @Test("an nprofile maps to a p tag carrying its first relay hint")
    func nprofileMapsToPubkeyTagWithRelay() throws {
        let profile = try NProfile(
            publicKey: pubkeyHex,
            relays: ["wss://relay.example.com", "wss://relay2.example.com"]
        )
        let uri = try NIP19Entity.nprofile(profile).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(reference.tag.rawArray == ["p", pubkeyHex, "wss://relay.example.com"])
    }

    @Test("a note maps to a q tag")
    func noteMapsToQuoteTag() {
        let content = "nostr:\(noteVector)"
        let reference = NostrContentReference.references(in: content).first
        #expect(reference?.tag.rawArray == ["q", noteIdHex])
    }

    @Test("an nevent with author maps to a q tag with relay and pubkey")
    func neventMapsToQuoteTagWithRelayAndPubkey() throws {
        let event = try NEvent(
            eventId: eventIdHex,
            relays: ["wss://relay.example.com"],
            author: pubkeyHex,
            kind: 1
        )
        let uri = try NIP19Entity.nevent(event).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(reference.tag.rawArray == ["q", eventIdHex, "wss://relay.example.com", pubkeyHex])
    }

    @Test("an naddr maps to an a tag with its coordinate and relay hint")
    func naddrMapsToAddressTag() throws {
        let addr = try NAddr(
            identifier: "1700847963",
            author: pubkeyHex,
            kind: 30023,
            relays: ["wss://relay3.example.com"]
        )
        let uri = try NIP19Entity.naddr(addr).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(
            reference.tag.rawArray == [
                "a", "30023:\(pubkeyHex):1700847963", "wss://relay3.example.com",
            ]
        )
    }

    // MARK: - tags(for:)

    @Test("tags(for:) deduplicates a repeated mention, preserving first-seen order")
    func tagsDeduplicateRepeatedMention() {
        let content = "hi nostr:\(npubVector) and again nostr:\(npubVector)"
        let tags = NostrContentReference.tags(for: content)
        #expect(tags.count == 1)
        #expect(tags[0].rawArray == ["p", npubPubkeyHex])
    }

    @Test("tags(for:) keeps distinct references in first-seen order")
    func tagsKeepDistinctReferences() {
        let content = "nostr:\(noteVector) then nostr:\(npubVector)"
        let tags = NostrContentReference.tags(for: content)
        #expect(tags.map(\.rawArray) == [["q", noteIdHex], ["p", npubPubkeyHex]])
    }

    // MARK: - Tag.quote padding

    @Test("Tag.quote pads a skipped relay when a pubkey is present")
    func quoteTagPadsSkippedRelay() {
        #expect(Event.Tag.quote("id", pubkey: "pk").rawArray == ["q", "id", "", "pk"])
    }

    @Test("Tag.quote with only an id emits a two-element tag")
    func quoteTagIdOnly() {
        #expect(Event.Tag.quote("id").rawArray == ["q", "id"])
    }
}
