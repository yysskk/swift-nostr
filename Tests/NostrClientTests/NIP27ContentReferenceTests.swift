import Foundation
import NostrCore
import NostrTestSupport
import Testing

@testable import NostrClient

@Suite("NIP-27 Content Reference Tests")
struct NIP27ContentReferenceTests {
    // Canonical NIP-19 spec vectors, reused from the NIP-19/NIP-21 suites.
    let publicKeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let eventIDHex = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"
    let npubVector = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    let npubKeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let noteVector = "note1fntxtkcy9pjwucqwa9mddn7v03wwwsu9j330jj350nvhpky2tuaspk6nqc"
    let noteIDHex = "4cd665db042864ee600ee976d6cfcc7c5ce743859462f94a347cd970d88a5f3b"

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
        #expect(reference.entity == .npub(PublicKey(npubKeyHex)!))
    }

    @Test("a case-folding-unstable character before a reference keeps the range accurate")
    func referenceAfterExpandingUppercaseCharacter() throws {
        // `İ` (U+0130) lowercases to two scalars, so indices computed on a lowercased copy
        // would be shifted relative to the original content. The scanned range must still
        // slice the original content back to exactly the matched reference.
        let content = "İstanbul nostr:\(npubVector) gm"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 1)
        let reference = try #require(references.first)
        #expect(String(content[reference.range]) == reference.text)
        #expect(reference.text == "nostr:\(npubVector)")
        #expect(reference.entity == .npub(PublicKey(npubKeyHex)!))
    }

    @Test("multiple references are returned in order of appearance")
    func multipleReferencesInOrder() {
        let content = "see nostr:\(npubVector) and nostr:\(noteVector) today"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 2)
        #expect(references[0].entity == .npub(PublicKey(npubKeyHex)!))
        #expect(references[1].entity == .note(EventID(noteIDHex)!))
    }

    @Test("trailing punctuation is excluded from the match")
    func trailingPunctuationExcluded() {
        let content = "wow nostr:\(noteVector)!"
        let references = NostrContentReference.references(in: content)
        #expect(references.count == 1)
        #expect(references[0].text == "nostr:\(noteVector)")
        #expect(references[0].entity == .note(EventID(noteIDHex)!))
    }

    @Test("a letter before the scheme is not a word boundary and is not matched")
    func wordBoundaryRequiredBeforeScheme() {
        let content = "xnostr:\(npubVector)"
        #expect(NostrContentReference.references(in: content).isEmpty)
    }

    @Test("an nsec reference is skipped")
    func nsecReferenceSkipped() throws {
        let nsecBech32 = try PrivateKey(hex: publicKeyHex).nsec
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
    func npubMapsToPublicKeyTag() {
        let content = "nostr:\(npubVector)"
        let reference = NostrContentReference.references(in: content).first
        #expect(reference?.tag.rawArray == ["p", npubKeyHex])
    }

    @Test("an nprofile maps to a p tag carrying its first relay hint")
    func nprofileMapsToPublicKeyTagWithRelay() throws {
        let profile = try NProfile(
            publicKey: PublicKey(publicKeyHex)!,
            relays: [RelayURL("wss://relay.example.com")!, RelayURL("wss://relay2.example.com")!]
        )
        let uri = try NIP19Entity.nprofile(profile).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(reference.tag.rawArray == ["p", publicKeyHex, "wss://relay.example.com"])
    }

    @Test("an nprofile skips relay hints that are not relay URLs")
    func nprofileSkipsMalformedRelayHints() throws {
        let nprofile = try RawTLV.bech32(
            prefix: "nprofile",
            special: PublicKey(publicKeyHex)!.data,
            relays: ["https://not-a-relay.example.com", "WSS://Relay2.Example.com/"]
        )
        let reference = try #require(NostrContentReference.references(in: "nostr:\(nprofile)").first)
        #expect(reference.tag.rawArray == ["p", publicKeyHex, "wss://relay2.example.com"])
    }

    @Test("a note maps to a q tag")
    func noteMapsToQuoteTag() {
        let content = "nostr:\(noteVector)"
        let reference = NostrContentReference.references(in: content).first
        #expect(reference?.tag.rawArray == ["q", noteIDHex])
    }

    @Test("an nevent with author maps to a q tag with relay and public key")
    func neventMapsToQuoteTagWithRelayAndPublicKey() throws {
        let event = try NEvent(
            eventID: EventID(eventIDHex)!,
            relays: [RelayURL("wss://relay.example.com")!],
            author: PublicKey(publicKeyHex)!,
            kind: 1
        )
        let uri = try NIP19Entity.nevent(event).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(reference.tag.rawArray == ["q", eventIDHex, "wss://relay.example.com", publicKeyHex])
    }

    @Test("an naddr maps to an a tag with its coordinate and relay hint")
    func naddrMapsToAddressTag() throws {
        let addr = try NAddr(
            identifier: "1700847963",
            author: PublicKey(publicKeyHex)!,
            kind: 30023,
            relays: [RelayURL("wss://relay3.example.com")!]
        )
        let uri = try NIP19Entity.naddr(addr).nostrURI
        let reference = try #require(NostrContentReference.references(in: uri).first)
        #expect(
            reference.tag.rawArray == [
                "a", "30023:\(publicKeyHex):1700847963", "wss://relay3.example.com",
            ]
        )
    }

    // MARK: - tags(for:)

    @Test("tags(for:) deduplicates a repeated mention, preserving first-seen order")
    func tagsDeduplicateRepeatedMention() {
        let content = "hi nostr:\(npubVector) and again nostr:\(npubVector)"
        let tags = NostrContentReference.tags(for: content)
        #expect(tags.count == 1)
        #expect(tags[0].rawArray == ["p", npubKeyHex])
    }

    @Test("tags(for:) keeps distinct references in first-seen order")
    func tagsKeepDistinctReferences() {
        let content = "nostr:\(noteVector) then nostr:\(npubVector)"
        let tags = NostrContentReference.tags(for: content)
        #expect(tags.map(\.rawArray) == [["q", noteIDHex], ["p", npubKeyHex]])
    }

    // MARK: - Tag.quote padding

    @Test("Tag.quote pads a skipped relay when a public key is present")
    func quoteTagPadsSkippedRelay() {
        let id = EventID.fixture("id")
        let publicKey = PublicKey.fixture("pk")
        #expect(Event.Tag.quote(id, publicKey: publicKey).rawArray == ["q", id.hex, "", publicKey.hex])
    }

    @Test("Tag.quote with only an id emits a two-element tag")
    func quoteTagIDOnly() {
        let id = EventID.fixture("id")
        #expect(Event.Tag.quote(id).rawArray == ["q", id.hex])
    }
}
