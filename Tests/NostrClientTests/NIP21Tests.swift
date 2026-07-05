import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-21 Nostr URI Tests")
struct NIP21Tests {
    // Canonical NIP-21 spec examples.
    // https://github.com/nostr-protocol/nips/blob/master/21.md
    let npubURI = "nostr:npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9"
    let nprofileURI =
        "nostr:nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"
    let noteURI = "nostr:note1fntxtkcy9pjwucqwa9mddn7v03wwwsu9j330jj350nvhpky2tuaspk6nqc"

    let pubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let eventIdHex = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"

    // MARK: - spec examples round-trip

    @Test("npub URI decodes and round-trips to the canonical form")
    func npubRoundTrip() throws {
        let entity = try NIP19Entity(nostrURI: npubURI)
        guard case .npub = entity else {
            Issue.record("expected npub")
            return
        }
        #expect(try entity.nostrURI == npubURI)
    }

    @Test("nprofile URI decodes and round-trips to the canonical form")
    func nprofileRoundTrip() throws {
        let entity = try NIP19Entity(nostrURI: nprofileURI)
        guard case .nprofile = entity else {
            Issue.record("expected nprofile")
            return
        }
        #expect(try entity.nostrURI == nprofileURI)
    }

    @Test("note URI decodes and round-trips to the canonical form")
    func noteRoundTrip() throws {
        let entity = try NIP19Entity(nostrURI: noteURI)
        guard case .note = entity else {
            Issue.record("expected note")
            return
        }
        #expect(try entity.nostrURI == noteURI)
    }

    // MARK: - nevent / naddr round-trip via constructed entities

    @Test("nevent round-trips through its nostr: URI")
    func neventRoundTrip() throws {
        let event = try NEvent(
            eventId: eventIdHex,
            relays: ["wss://relay.example.com"],
            author: pubkeyHex,
            kind: 1
        )
        let uri = try NIP19Entity.nevent(event).nostrURI
        #expect(uri.hasPrefix("nostr:nevent1"))
        #expect(try NIP19Entity(nostrURI: uri) == .nevent(event))
    }

    @Test("naddr round-trips through its nostr: URI")
    func naddrRoundTrip() throws {
        let addr = try NAddr(
            identifier: "1700847963",
            author: pubkeyHex,
            kind: 30023,
            relays: ["wss://relay3.example.com"]
        )
        let uri = try NIP19Entity.naddr(addr).nostrURI
        #expect(uri.hasPrefix("nostr:naddr1"))
        #expect(try NIP19Entity(nostrURI: uri) == .naddr(addr))
    }

    // MARK: - scheme tolerance

    @Test("a nostr:// URI with slashes decodes to the canonical slash-free form")
    func slashesTolerated() throws {
        let withSlashes = "nostr://npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9"
        let entity = try NIP19Entity(nostrURI: withSlashes)
        #expect(try entity.nostrURI == npubURI)
    }

    @Test("an uppercase NOSTR: scheme decodes to the canonical lowercase form")
    func uppercaseSchemeTolerated() throws {
        let uppercase = "NOSTR:npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9"
        let entity = try NIP19Entity(nostrURI: uppercase)
        #expect(try entity.nostrURI == npubURI)
    }

    // MARK: - nsec is rejected both ways

    @Test("decoding an nsec URI throws invalidNostrURI")
    func nsecURIRejected() throws {
        // Source a valid nsec bech32 by encoding a 32-byte key through the existing API.
        let nsecBech32 = try NIP19Entity.nsec(pubkeyHex).encoded
        #expect(throws: NostrError.invalidNostrURI) {
            _ = try NIP19Entity(nostrURI: "nostr:" + nsecBech32)
        }
    }

    @Test("encoding an nsec entity to a nostr: URI throws invalidNostrURI")
    func nsecEncodeRejected() {
        #expect(throws: NostrError.invalidNostrURI) {
            _ = try NIP19Entity.nsec(pubkeyHex).nostrURI
        }
    }

    // MARK: - malformed input

    @Test("a string without the nostr: scheme throws invalidNostrURI")
    func missingSchemeThrows() {
        let bare = "npub1sn0wdenkukak0d9dfczzeacvhkrgz92ak56egt7vdgzn8pv2wfqqhrjdv9"
        #expect(throws: NostrError.invalidNostrURI) {
            _ = try NIP19Entity(nostrURI: bare)
        }
    }

    @Test("garbage bech32 after the scheme throws")
    func garbageBech32Throws() {
        #expect(throws: (any Error).self) {
            _ = try NIP19Entity(nostrURI: "nostr:notavalidentity")
        }
    }
}
