import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("NIP-19 Entity Tests")
struct NIP19Tests {
    // Canonical NIP-19 fixtures.
    let publicKey = PublicKey("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d")!
    let eventID = EventID("5c83da77af1dec6d7289834998ad7aafbd9e2191396d75ec3cc27f5a77226f36")!
    let npubVector = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"
    let nprofileVector =
        "nprofile1qqsrhuxx8l9ex335q7he0f09aej04zpazpl0ne2cgukyawd24mayt8gpp4mhxue69uhhytnc9e3k7mgpz4mhxue69uhkg6nzv9ejuumpv34kytnrdaksjlyr9p"

    // MARK: - note

    @Test("note round-trips through encode/decode")
    func noteRoundTrip() throws {
        let encoded = try NIP19Entity.note(eventID).encoded
        #expect(encoded == eventID.note)
        #expect(try NIP19Entity.decode(encoded) == .note(eventID))
    }

    // MARK: - npub canonical vector

    @Test("decode canonical npub vector")
    func decodeNpubVector() throws {
        #expect(try NIP19Entity.decode(npubVector) == .npub(publicKey))
        #expect(try NIP19Entity.npub(publicKey).encoded == npubVector)
    }

    // MARK: - nprofile canonical vector (TLV correctness gate)

    @Test("decode canonical nprofile vector")
    func decodeNprofileVector() throws {
        guard case .nprofile(let profile) = try NIP19Entity.decode(nprofileVector) else {
            Issue.record("expected nprofile")
            return
        }
        #expect(profile.publicKey == publicKey)
        #expect(profile.relays == [RelayURL("wss://r.x.com")!, RelayURL("wss://djbas.sadkb.com")!])
    }

    @Test("encode nprofile matches canonical vector")
    func encodeNprofileVector() throws {
        let profile = try NProfile(
            publicKey: publicKey, relays: [RelayURL("wss://r.x.com")!, RelayURL("wss://djbas.sadkb.com")!])
        #expect(try profile.encoded == nprofileVector)
    }

    @Test("decoding skips relay hints that are not relay URLs and keeps the rest in order")
    func decodingSkipsMalformedRelayHints() throws {
        let hints = ["", "https://web.example.com", "WSS://R.Example.com/", "not a relay", "wss://s.example.com"]
        let expected = [RelayURL("wss://r.example.com")!, RelayURL("wss://s.example.com")!]

        let profile = try NProfile(
            bech32String: RawTLV.bech32(prefix: "nprofile", special: publicKey.data, relays: hints))
        #expect(profile.relays == expected)

        let eventID = EventID.fixture("note")
        let event = try NEvent(bech32String: RawTLV.bech32(prefix: "nevent", special: eventID.data, relays: hints))
        #expect(event.relays == expected)

        let addr = try NAddr(
            bech32String: RawTLV.bech32(
                prefix: "naddr", special: Data("d".utf8), relays: hints, author: publicKey, kind: 30023))
        #expect(addr.relays == expected)
    }

    @Test("encoding writes relay hints in canonical form")
    func encodingWritesCanonicalRelayHints() throws {
        let profile = try NProfile(publicKey: publicKey, relays: [RelayURL("WSS://R.X.com:443/")!])
        let canonical = try NProfile(publicKey: publicKey, relays: [RelayURL("wss://r.x.com")!])
        #expect(try profile.encoded == canonical.encoded)
        #expect(try NProfile(bech32String: profile.encoded).relays == [RelayURL("wss://r.x.com")!])
    }

    @Test("nprofile round-trips without relays")
    func nprofileRoundTripNoRelays() throws {
        let profile = try NProfile(publicKey: publicKey)
        let decoded = try NProfile(bech32String: profile.encoded)
        #expect(decoded == profile)
        #expect(decoded.relays.isEmpty)
    }

    // MARK: - nevent

    @Test("nevent round-trips with all fields")
    func neventRoundTripFull() throws {
        let event = try NEvent(
            eventID: eventID,
            relays: [RelayURL("wss://relay.example.com")!],
            author: publicKey,
            kind: 1
        )
        let encoded = try event.encoded
        #expect(encoded.hasPrefix("nevent1"))

        let decoded = try NEvent(bech32String: encoded)
        #expect(decoded == event)
        #expect(decoded.author == publicKey)
        #expect(decoded.kind == 1)
        #expect(decoded.relays == [RelayURL("wss://relay.example.com")!])
    }

    @Test("nevent round-trips with only the event id")
    func neventRoundTripMinimal() throws {
        let event = try NEvent(eventID: eventID)
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
            author: publicKey,
            kind: 30023,
            relays: [RelayURL("wss://relay3.example.com")!]
        )
        let encoded = try addr.encoded
        #expect(encoded.hasPrefix("naddr1"))

        let decoded = try NAddr(bech32String: encoded)
        #expect(decoded == addr)
        #expect(decoded.kind == 30023)
        #expect(decoded.identifier == "1700847963")
    }

    @Test("naddr round-trips with an empty identifier")
    func naddrRoundTripEmptyIdentifier() throws {
        let addr = try NAddr(identifier: "", author: publicKey, kind: 30000)
        let decoded = try NAddr(bech32String: addr.encoded)
        #expect(decoded == addr)
        #expect(decoded.identifier.isEmpty)
    }

    // MARK: - convenience inits from Event

    @Test("NEvent(event:) captures id, author, and kind")
    func neventFromEvent() throws {
        let event = makeEvent(kind: 1, tags: [])
        let nevent = try NEvent(event: event, relays: [RelayURL("wss://relay.example.com")!])
        #expect(nevent.eventID == eventID)
        #expect(nevent.author == publicKey)
        #expect(nevent.kind == 1)
        #expect(nevent.relays == [RelayURL("wss://relay.example.com")!])
    }

    @Test("NAddr(event:) extracts the d tag")
    func naddrFromEvent() throws {
        let event = makeEvent(kind: 30023, tags: [.hashtag("nostr"), .identifier("my-article")])
        let addr = try NAddr(event: event)
        #expect(addr.identifier == "my-article")
        #expect(addr.author == publicKey)
        #expect(addr.kind == 30023)
    }

    // MARK: - kind validation

    @Test("a kind of zero and a typical kind are valid")
    func validatedKindAcceptsInRange() throws {
        #expect(try TLV.validatedKind(0) == 0)
        #expect(try TLV.validatedKind(30023) == 30023)
    }

    @Test("a negative kind throws kindOutOfRange")
    func validatedKindRejectsNegative() {
        #expect(throws: NIP19Entity.Error.kindOutOfRange(-1)) {
            _ = try TLV.validatedKind(-1)
        }
    }

    @Test("the maximum 32-bit kind is valid and larger kinds throw")
    func validatedKindUpperBound() throws {
        // Values above Int32.max only fit in `Int` on 64-bit platforms; on 32-bit
        // targets (e.g. watchOS), `Int.max` == `Int32.max` < `UInt32.max`, so
        // `Int(exactly:)` returns `nil` and this boundary is unreachable there.
        guard let maximumKind = Int(exactly: UInt32.max) else { return }
        #expect(try TLV.validatedKind(maximumKind) == maximumKind)
        #expect(throws: NIP19Entity.Error.kindOutOfRange(maximumKind + 1)) {
            _ = try TLV.validatedKind(maximumKind + 1)
        }
    }

    // MARK: - error handling

    @Test("decoding with another entity's prefix throws unexpectedPrefix")
    func wrongPrefixThrows() {
        #expect(throws: NIP19Entity.Error.unexpectedPrefix("npub")) {
            _ = try NEvent(bech32String: npubVector)
        }
    }

    @Test("decoding a prefix NIP-19 does not define throws unknownPrefix")
    func unknownPrefixThrows() throws {
        let encoded = try Bech32.encode(hrp: "nfoo", data: Data(repeating: 0xAB, count: 32))
        #expect(throws: NIP19Entity.Error.unknownPrefix("nfoo")) {
            _ = try NIP19Entity.decode(encoded)
        }
    }

    @Test("decoding a string that is not bech32 throws invalidBech32")
    func invalidBech32Throws() {
        #expect(throws: NIP19Entity.Error.invalidBech32(.missingSeparator)) {
            _ = try NIP19Entity.decode("nothing")
        }
    }

    @Test("a truncated TLV record throws malformedTLV")
    func truncatedTLVThrows() throws {
        // A type byte with no length, then a record whose length runs past the payload.
        for tlv in [Data([0x00]), Data([0x00, 0x20]) + eventID.data.prefix(10)] {
            let encoded = try Bech32.encode(hrp: "nevent", data: tlv)
            #expect(throws: NIP19Entity.Error.malformedTLV) {
                _ = try NEvent(bech32String: encoded)
            }
        }
    }

    @Test("a kind record that is not 1 to 4 bytes throws invalidLength")
    func kindRecordOfWrongLengthThrows() throws {
        let tlv = Data([0x00, 0x20]) + eventID.data + Data([0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x01])
        let encoded = try Bech32.encode(hrp: "nevent", data: tlv)
        #expect(throws: NIP19Entity.Error.invalidLength(5)) {
            _ = try NEvent(bech32String: encoded)
        }
    }

    @Test("a relay hint longer than 255 bytes throws fieldTooLong")
    func longRelayHintThrows() throws {
        let relay = try RelayURL(string: "wss://relay.example/" + String(repeating: "a", count: 300))
        let length = relay.description.utf8.count
        #expect(throws: NIP19Entity.Error.fieldTooLong(length)) {
            _ = try NProfile(publicKey: publicKey, relays: [relay])
        }
    }

    @Test("an naddr identifier longer than 255 bytes throws fieldTooLong when encoded")
    func longIdentifierThrowsOnEncode() throws {
        let naddr = try NAddr(identifier: String(repeating: "x", count: 256), author: publicKey, kind: 30023)
        #expect(throws: NIP19Entity.Error.fieldTooLong(256)) {
            _ = try naddr.encoded
        }
    }

    @Test(
        "a bare npub, nsec, or note whose payload is not 32 bytes throws invalidLength",
        arguments: ["npub", "nsec", "note"], [31, 33])
    func barePayloadOfWrongLengthThrows(prefix: String, byteCount: Int) throws {
        let encoded = try Bech32.encode(hrp: prefix, data: Data(repeating: 0xAB, count: byteCount))
        #expect(throws: NIP19Entity.Error.invalidLength(byteCount)) {
            _ = try NIP19Entity.decode(encoded)
        }
    }

    @Test("an nprofile whose public key is not 32 bytes throws invalidLength")
    func nprofileShortPublicKeyThrows() throws {
        let tlv = Data([0x00, 0x1F]) + publicKey.data.prefix(31)
        let encoded = try Bech32.encode(hrp: "nprofile", data: tlv)
        #expect(throws: NIP19Entity.Error.invalidLength(31)) {
            _ = try NProfile(bech32String: encoded)
        }
    }

    @Test("an nprofile without a public key throws missingPublicKey")
    func nprofileMissingPublicKeyThrows() throws {
        let tlv = Data([0x01, 0x13]) + Data("wss://relay.example".utf8)
        let encoded = try Bech32.encode(hrp: "nprofile", data: tlv)
        #expect(throws: NIP19Entity.Error.missingPublicKey) {
            _ = try NProfile(bech32String: encoded)
        }
    }

    @Test("an nevent whose event id or author is not 32 bytes throws invalidLength")
    func neventMalformedRecordsThrow() throws {
        let shortID = Data([0x00, 0x1F]) + eventID.data.prefix(31)
        let longAuthor = Data([0x00, 0x20]) + eventID.data + Data([0x02, 0x21]) + publicKey.data + Data([0x00])
        for (tlv, count) in [(shortID, 31), (longAuthor, 33)] {
            let encoded = try Bech32.encode(hrp: "nevent", data: tlv)
            #expect(throws: NIP19Entity.Error.invalidLength(count)) {
                _ = try NEvent(bech32String: encoded)
            }
        }
    }

    @Test("an naddr whose author is not 32 bytes throws invalidLength")
    func naddrShortAuthorThrows() throws {
        let tlv =
            Data([0x00, 0x03]) + Data("abc".utf8)
            + Data([0x02, 0x1F]) + publicKey.data.prefix(31)
            + Data([0x03, 0x04, 0x00, 0x00, 0x75, 0x27])
        let encoded = try Bech32.encode(hrp: "naddr", data: tlv)
        #expect(throws: NIP19Entity.Error.invalidLength(31)) {
            _ = try NAddr(bech32String: encoded)
        }
    }

    @Test("an nevent without an event id throws missingEventID")
    func neventMissingIDThrows() throws {
        let encoded = try Bech32.encode(hrp: "nevent", data: Data([0x02, 0x20]) + publicKey.data)
        #expect(throws: NIP19Entity.Error.missingEventID) {
            _ = try NEvent(bech32String: encoded)
        }
    }

    @Test("an naddr missing a required record throws the matching missing case")
    func naddrMissingRecordsThrow() throws {
        let identifier = Data([0x00, 0x03]) + Data("abc".utf8)
        let author = Data([0x02, 0x20]) + publicKey.data
        let kind = Data([0x03, 0x04, 0x00, 0x00, 0x75, 0x27])
        let cases: [(Data, NIP19Entity.Error)] = [
            (author + kind, .missingIdentifier),
            (identifier + kind, .missingAuthor),
            (identifier + author, .missingKind),
        ]
        for (tlv, expected) in cases {
            let encoded = try Bech32.encode(hrp: "naddr", data: tlv)
            #expect(throws: expected) {
                _ = try NAddr(bech32String: encoded)
            }
        }
    }

    // MARK: - forward compatibility

    @Test("unknown TLV types are ignored on decode")
    func unknownTLVIgnored() throws {
        // type 0 = public key (32 bytes), type 9 = unknown 2-byte payload.
        var tlv = Data([0x00, 0x20]) + publicKey.data
        tlv += Data([0x09, 0x02, 0xAB, 0xCD])
        let encoded = try Bech32.encode(hrp: "nprofile", data: tlv)

        guard case .nprofile(let profile) = try NIP19Entity.decode(encoded) else {
            Issue.record("expected nprofile")
            return
        }
        #expect(profile.publicKey == publicKey)
    }

    // MARK: - helpers

    private func makeEvent(kind: Event.Kind, tags: [Event.Tag]) -> Event {
        Event(
            id: eventID,
            publicKey: publicKey,
            createdAt: Timestamp(rawValue: 0),
            kind: kind,
            tags: tags,
            content: "",
            signature: Signature(String(repeating: "0", count: 128))!
        )
    }
}
