import Foundation
import Testing

@testable import NostrClient

@Suite("NIP-19 Entity Tests")
struct NIP19Tests {
    // Canonical NIP-19 fixtures.
    let pubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    let eventIdHex = "5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36"
    let npubVector = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    let nprofileVector =
        "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"

    // MARK: - note

    @Test("note round-trips through encode/decode")
    func noteRoundTrip() throws {
        let encoded = NIP19Entity.note(eventIdHex).encoded
        #expect(encoded.hasPrefix("note1"))
        #expect(try NIP19Entity.decode(encoded) == .note(eventIdHex))
    }

    // MARK: - npub canonical vector

    @Test("decode canonical npub vector")
    func decodeNpubVector() throws {
        #expect(try NIP19Entity.decode(npubVector) == .npub(pubkeyHex))
    }

    // MARK: - nprofile canonical vector (TLV correctness gate)

    @Test("decode canonical nprofile vector")
    func decodeNprofileVector() throws {
        guard case .nprofile(let profile) = try NIP19Entity.decode(nprofileVector) else {
            Issue.record("expected nprofile")
            return
        }
        #expect(profile.publicKey == pubkeyHex)
        #expect(profile.relays == ["wss://r.x.com", "wss://djbas.sadkb.com"])
    }

    @Test("encode nprofile matches canonical vector")
    func encodeNprofileVector() throws {
        let profile = try NProfile(publicKey: pubkeyHex, relays: ["wss://r.x.com", "wss://djbas.sadkb.com"])
        #expect(profile.encoded == nprofileVector)
    }

    @Test("nprofile round-trips without relays")
    func nprofileRoundTripNoRelays() throws {
        let profile = try NProfile(publicKey: pubkeyHex)
        let decoded = try NProfile(bech32String: profile.encoded)
        #expect(decoded == profile)
        #expect(decoded.relays.isEmpty)
    }

    // MARK: - nevent

    @Test("nevent round-trips with all fields")
    func neventRoundTripFull() throws {
        let event = try NEvent(
            eventId: eventIdHex,
            relays: ["wss://relay.damus.io"],
            author: pubkeyHex,
            kind: 1
        )
        let encoded = event.encoded
        #expect(encoded.hasPrefix("nevent1"))

        let decoded = try NEvent(bech32String: encoded)
        #expect(decoded == event)
        #expect(decoded.author == pubkeyHex)
        #expect(decoded.kind == 1)
        #expect(decoded.relays == ["wss://relay.damus.io"])
    }

    @Test("nevent round-trips with only the event id")
    func neventRoundTripMinimal() throws {
        let event = try NEvent(eventId: eventIdHex)
        let decoded = try NEvent(bech32String: event.encoded)
        #expect(decoded == event)
        #expect(decoded.author == nil)
        #expect(decoded.kind == nil)
        #expect(decoded.relays.isEmpty)
    }

    // MARK: - naddr

    @Test("naddr round-trips with all fields")
    func naddrRoundTripFull() throws {
        let addr = try NAddr(
            identifier: "1700847963",
            author: pubkeyHex,
            kind: 30023,
            relays: ["wss://relay.nostr.band"]
        )
        let encoded = addr.encoded
        #expect(encoded.hasPrefix("naddr1"))

        let decoded = try NAddr(bech32String: encoded)
        #expect(decoded == addr)
        #expect(decoded.kind == 30023)
        #expect(decoded.identifier == "1700847963")
    }

    @Test("naddr round-trips with an empty identifier")
    func naddrRoundTripEmptyIdentifier() throws {
        let addr = try NAddr(identifier: "", author: pubkeyHex, kind: 30000)
        let decoded = try NAddr(bech32String: addr.encoded)
        #expect(decoded == addr)
        #expect(decoded.identifier.isEmpty)
    }

    // MARK: - convenience inits from Event

    @Test("NEvent(event:) captures id, author, and kind")
    func neventFromEvent() throws {
        let event = makeEvent(kind: 1, tags: [])
        let nevent = try NEvent(event: event, relays: ["wss://relay.damus.io"])
        #expect(nevent.eventId == eventIdHex)
        #expect(nevent.author == pubkeyHex)
        #expect(nevent.kind == 1)
        #expect(nevent.relays == ["wss://relay.damus.io"])
    }

    @Test("NAddr(event:) extracts the d tag")
    func naddrFromEvent() throws {
        let event = makeEvent(kind: 30023, tags: [["t", "nostr"], ["d", "my-article"]])
        let addr = try NAddr(event: event)
        #expect(addr.identifier == "my-article")
        #expect(addr.author == pubkeyHex)
        #expect(addr.kind == 30023)
    }

    // MARK: - error handling

    @Test("decoding with the wrong prefix throws unknownPrefix")
    func wrongPrefixThrows() {
        #expect(throws: NostrError.unknownPrefix("npub")) {
            _ = try NEvent(bech32String: npubVector)
        }
    }

    @Test("invalid hex throws invalidHex")
    func invalidHexThrows() {
        #expect(throws: NostrError.invalidHex) {
            _ = try NProfile(publicKey: "zz")
        }
    }

    @Test("naddr missing required author throws invalidNIP19Entity")
    func naddrMissingAuthorThrows() {
        // TLV with only a type-0 identifier ("abc"); no author or kind.
        let tlv = Data([0x00, 0x03]) + Data("abc".utf8)
        let encoded = Bech32.encode(hrp: "naddr", data: tlv)
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try NAddr(bech32String: encoded)
        }
    }

    // MARK: - forward compatibility

    @Test("unknown TLV types are ignored on decode")
    func unknownTLVIgnored() throws {
        guard let pubkey = Data(hexString: pubkeyHex) else {
            Issue.record("bad fixture")
            return
        }
        // type 0 = pubkey (32 bytes), type 9 = unknown 2-byte payload.
        var tlv = Data([0x00, 0x20]) + pubkey
        tlv += Data([0x09, 0x02, 0xAB, 0xCD])
        let encoded = Bech32.encode(hrp: "nprofile", data: tlv)

        guard case .nprofile(let profile) = try NIP19Entity.decode(encoded) else {
            Issue.record("expected nprofile")
            return
        }
        #expect(profile.publicKey == pubkeyHex)
    }

    // MARK: - helpers

    private func makeEvent(kind: Event.Kind, tags: [[String]]) -> Event {
        Event(
            id: eventIdHex,
            pubkey: pubkeyHex,
            createdAt: 0,
            kind: kind,
            tags: tags,
            content: "",
            sig: String(repeating: "0", count: 128)
        )
    }
}
