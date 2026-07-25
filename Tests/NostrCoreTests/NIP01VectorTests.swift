import Foundation
import NostrCore
import Testing

/// Known-answer tests for the NIP-01 canonical event serialization, its sha256 event id, and
/// BIP-340 signature interoperability.
///
/// https://github.com/nostr-protocol/nips/blob/master/01.md
/// https://github.com/bitcoin/bips/blob/master/bip-0340/bip-0340.mediawiki
///
/// An event's id is the sha256 of `[0,pubkey,created_at,kind,tags,content]` serialized with no
/// insignificant whitespace and with the escaping rules NIP-01 spells out. That makes the exact
/// bytes consensus-critical: one differing byte yields a different hash, hence a different id,
/// and every other client rejects the event as having an invalid id — or silently never resolves
/// the replies, reactions, and deletions that reference it. Round-trip tests cannot catch this,
/// because a serializer that is uniformly wrong still signs and verifies against itself. So the
/// expectations below are pinned to values produced outside this code base.
///
/// **Provenance / how to re-derive every value here.** No generator script is committed; each
/// value can be reproduced from a stock Python 3:
///
/// - Serializations: `json.dumps([0, pubkey, created_at, kind, tags, content],`
///   `separators=(",", ":"), ensure_ascii=False).encode("utf-8")`. For these inputs that is
///   byte-identical to JavaScript's `JSON.stringify` and to Rust's `serde_json::to_vec`, which is
///   what the rest of the ecosystem runs.
/// - Event ids: `hashlib.sha256(serialization).hexdigest()`, cross-checked with
///   `printf '%s' '<serialization>' | shasum -a 256`.
/// - Signatures: the BIP-340 reference implementation (`bip-0340/reference.py`) as
///   `schnorr_sign(bytes.fromhex(event_id), secret_key, bytes(32))` — that is, over the 32-byte
///   event id with all-zero auxiliary randomness, which makes them deterministic and reproducible.
///   Each vector records the secret key it was signed with. The two keys used are 1, whose x-only
///   public key is secp256k1's generator x-coordinate, and `b7e1…cfef`, BIP-340's own test-vector
///   key; both public keys below appear verbatim in BIP-340's published vectors.
@Suite("NIP-01 Vector Tests")
struct NIP01VectorTests {
    /// The x-only public key for secret key 1 — the x-coordinate of secp256k1's generator point.
    static let pubkey1 = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

    /// The x-only public key for secret key `b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef`,
    /// the key BIP-340's own test vectors use.
    static let pubkey2 = "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659"

    /// A fixed, arbitrary `created_at`.
    static let timestamp: Int64 = 1_700_000_000

    /// 9999-12-31T23:59:59Z: past the Int32 range, so a 32-bit truncation shows up as a broken id.
    static let farFutureTimestamp: Int64 = 253_402_300_799

    /// One canonical-serialization vector: the event fields, the exact bytes they must
    /// serialize to, and the resulting event id.
    struct SerializationVector: CustomTestStringConvertible {
        let label: String
        let pubkey: String
        let createdAt: Int64
        let kind: Event.Kind
        let rawTags: [[String]]
        let content: String
        let expectedSerialization: String
        let expectedId: String

        var testDescription: String { label }
    }

    static let serializationVectors: [SerializationVector] = [
        // A1: plain ASCII content — the baseline shape of the serialized array.
        SerializationVector(
            label: "A1 basic ascii",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [],
            content: "hello world",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[],"hello world"]"#,
            expectedId: "6db73c0791345150952b66916ca160efb6aef7734b982dda3d818360a1b60ee1"
        ),
        // A2: empty content — the shortest serialization an event can have.
        SerializationVector(
            label: "A2 empty content",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [],
            content: "",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[],""]"#,
            expectedId: "1868e8ad4ca66b7a9bb6ddaaecde6e5cc5d11682e87abb650a6ce8853854ef05"
        ),
        // A3: all seven escapes NIP-01 mandates, in the content: quote, backslash,
        // line break, carriage return, tab, backspace, and form feed.
        SerializationVector(
            label: "A3 escapes in content",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [],
            content: "quote:\" backslash:\\ newline:\n return:\r tab:\t backspace:\u{08} formfeed:\u{0C}",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[],"quote:\" backslash:\\ newline:\n return:\r tab:\t backspace:\b formfeed:\f"]"#,
            expectedId: "21dd099446a06e6f3ca9011458b62bf895810f8ff217a7dc596c76a7e7b3cddc"
        ),
        // A4: the same escaping inside tag values — tags are ordinary JSON strings, so a
        // serializer that only escapes the content produces a different id here.
        SerializationVector(
            label: "A4 escapes in tag values",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [["t", "multi\nline\tvalue"], ["title", "a \"quoted\" \\ title"], ["x", "\r\u{08}\u{0C}"]],
            content: "escapes in tags",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[["t","multi\nline\tvalue"],["title","a \"quoted\" \\ title"],["x","\r\b\f"]],"#
                + #""escapes in tags"]"#,
            expectedId: "915df4ad7c71e4bc25a52d1685265aae1af14f91ec0e4ab8223bd5b8c5186704"
        ),
        // A5: forward slashes stay verbatim. Escaping them as `\/` is valid JSON and is what
        // Foundation does by default, so this pins the `.withoutEscapingSlashes` behaviour —
        // the single most likely way a Swift client silently computes foreign ids.
        SerializationVector(
            label: "A5 unescaped forward slashes",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [["r", "wss://relay.example.com/"], ["proxy", "https://example.com/a/b?c=d#e"]],
            content: "read https://example.com/path/to/page?q=1&x=/y and a/b",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[["r","wss://relay.example.com/"],["proxy","https://example.com/a/b?c=d#e"]],"#
                + #""read https://example.com/path/to/page?q=1&x=/y and a/b"]"#,
            expectedId: "0a78af0227d63a7ac63665dfdbbdb984eeee4fefd9f08c47c49d16667aadf71d"
        ),
        // A6: four multi-element tags, including NIP-10 markers and the empty-string
        // placeholder for a skipped relay hint. Tag order and inner order must be preserved.
        SerializationVector(
            label: "A6 multi-element tags",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [
                [
                    "e",
                    "1111111111111111111111111111111111111111111111111111111111111111",
                    "wss://relay.example.com",
                    "root",
                ],
                ["e", "2222222222222222222222222222222222222222222222222222222222222222", "", "reply"],
                ["p", "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659", "wss://relay.example.com"],
                [
                    "a",
                    "30023:79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798:my-article",
                    "wss://relay.example.com",
                ],
            ],
            content: "reply with markers",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,1,[["e","1111111111111111111111111111111111111111111111111111111111111111","#
                + #""wss://relay.example.com","root"],["e","222222222222222222222222222222222222222222222222222222"#
                + #"2222222222","","reply"],["p","dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659"#
                + #"","wss://relay.example.com"],["a","30023:79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f28"#
                + #"15b16f81798:my-article","wss://relay.example.com"]],"reply with markers"]"#,
            expectedId: "396e2037b00e5beff06704a113ee7957cc9e1d2c0daa706504de77579f0cf2c4"
        ),
        // A7: a kind-0 profile whose content is itself JSON — its quotes and backslashes are
        // escaped a second time, and the content must not be re-encoded as a nested object.
        SerializationVector(
            label: "A7 kind 0 json-in-content",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 0,
            rawTags: [],
            content:
                "{\"name\":\"fiatjaf\",\"about\":\"nostr \\\"author\\\"\",\"picture\":\"https://example.com/p.jpg\"}",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,0,[],"{\"name\":\"fiatjaf\",\"about\":\"nostr \\\"author\\\"\","#
                + #"\"picture\":\"https://example.com/p.jpg\"}"]"#,
            expectedId: "4e8e56d27f6882577b1f205d48dd6832e264c227ab526156cff6c97fc89f4cd8"
        ),
        // A8: a far-future timestamp that overflows Int32, with an addressable kind. Pins that
        // created_at is emitted as a bare integer and never as a float or a quoted string.
        SerializationVector(
            label: "A8 large timestamp, addressable kind",
            pubkey: pubkey1,
            createdAt: farFutureTimestamp,
            kind: 30023,
            rawTags: [["d", "nip01-kat"], ["published_at", "253402300799"]],
            content: "far-future long-form",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"253402300799,30023,[["d","nip01-kat"],["published_at","253402300799"]],"far-future long-form"]"#,
            expectedId: "27a20b59dc93c5f1893b9a0b5fc4daf818879a17bb591fd4c94be19b609f0011"
        ),
        // A9: a five-digit kind, serialized as a bare integer.
        SerializationVector(
            label: "A9 large kind",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 65535,
            rawTags: [],
            content: "large kind",
            expectedSerialization:
                #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
                + #"1700000000,65535,[],"large kind"]"#,
            expectedId: "66913b9eefae064e13cd27eec93389727795a2fcb8f3c404ffe9358c410e4075"
        ),
    ]

    /// One signature vector: an event whose id and BIP-340 signature were both produced
    /// outside this code base, so verifying them checks interoperability rather than
    /// self-consistency.
    struct SignatureVector: CustomTestStringConvertible {
        let label: String
        /// The secret key the pinned signature was produced with, recorded so the vector
        /// can be regenerated. Never used by the tests — verification needs only the pubkey.
        let secretKey: String
        let pubkey: String
        let createdAt: Int64
        let kind: Event.Kind
        let rawTags: [[String]]
        let content: String
        let id: String
        let sig: String

        var testDescription: String { label }

        var unsignedEvent: UnsignedEvent {
            UnsignedEvent(
                pubkey: pubkey,
                createdAt: createdAt,
                kind: kind,
                rawTags: rawTags,
                content: content
            )
        }

        /// The pinned event, reassembled with an overridden `content` where a test needs to
        /// tamper with it.
        func event(content overriddenContent: String? = nil, sig overriddenSig: String? = nil) -> Event {
            Event(
                id: id,
                pubkey: pubkey,
                createdAt: createdAt,
                kind: kind,
                tags: rawTags,
                content: overriddenContent ?? content,
                sig: overriddenSig ?? sig
            )
        }
    }

    static let signatureVectors: [SignatureVector] = [
        // S1: the A1 event, signed with secret key 1.
        SignatureVector(
            label: "S1 sk=1, kind 1",
            secretKey: "0000000000000000000000000000000000000000000000000000000000000001",
            pubkey: pubkey1,
            createdAt: timestamp,
            kind: 1,
            rawTags: [],
            content: "hello world",
            id: "6db73c0791345150952b66916ca160efb6aef7734b982dda3d818360a1b60ee1",
            sig:
                "357ad83f176b67f0f8ce5ecc9999f716f301b31cb8a8679ed57d7ba70e46fb91"
                + "b92c6747f0cc9f355bac75556e6cba2530cf8af8c2735c4081adcda65c961a72"
        ),
        // S2: BIP-340's own test-vector secret key over content holding a quote, a backslash,
        // a line break, and an unescaped URL — a serialization bug and a signing bug would both
        // surface here, and the id assertion tells them apart.
        SignatureVector(
            label: "S2 sk=b7e1…cfef, escapes and a url",
            secretKey: "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef",
            pubkey: pubkey2,
            createdAt: timestamp,
            kind: 1,
            rawTags: [["t", "interop"], ["client", "swift-nostr"]],
            content: "escape interop \" \\ \n and https://relay.example.com/path",
            id: "0e9d6673e2998438048d0b28cbb4d12ce2c609966e2d3e28db3d4bc2751d8b60",
            sig:
                "68c2a7556e1a067b6186c42090f3b36e23603ecd1bdeb47e3f2fe0574e75d20b"
                + "a62549795f3b4d5ccd1a004eab7f6f0dc5c22e55e7492f8845de12db8d0b1d25"
        ),
        // S3: the A8 event, signed with secret key 1.
        SignatureVector(
            label: "S3 sk=1, addressable kind",
            secretKey: "0000000000000000000000000000000000000000000000000000000000000001",
            pubkey: pubkey1,
            createdAt: farFutureTimestamp,
            kind: 30023,
            rawTags: [["d", "nip01-kat"], ["published_at", "253402300799"]],
            content: "far-future long-form",
            id: "27a20b59dc93c5f1893b9a0b5fc4daf818879a17bb591fd4c94be19b609f0011",
            sig:
                "e8f7037ab174bad8292b58fad78f2e4dd0f3e584845a3db66896ac3b4e47ca33"
                + "7c7baf3af2024a818d1fea30f0c611c25c4f38f5f1bab93533d8d6821ccd4c4b"
        ),
    ]

    /// The core known-answer test: the serialized bytes and the derived id must match the
    /// reference values exactly, not merely contain the right substrings.
    @Test("canonical serialization and event id match the reference vectors", arguments: serializationVectors)
    func canonicalSerializationMatchesVector(_ vector: SerializationVector) throws {
        let unsigned = UnsignedEvent(
            pubkey: vector.pubkey,
            createdAt: vector.createdAt,
            kind: vector.kind,
            rawTags: vector.rawTags,
            content: vector.content
        )

        let serialized = try unsigned.serializedForHashing()

        #expect(String(decoding: serialized, as: UTF8.self) == vector.expectedSerialization)
        #expect(try unsigned.computedId == vector.expectedId)
    }

    /// Non-ASCII text is emitted as raw UTF-8, never as `\uXXXX` escapes, and surrogate
    /// pairs are never introduced for astral characters such as the rocket. The strings are
    /// embedded as hex so the exact bytes — including NFC-precomposed `é` and `ö` — survive
    /// any editor or normalization pass over this file.
    @Test("non-ascii content and tags serialize as verbatim utf-8")
    func nonASCIIContentSerializesVerbatim() throws {
        // "日本語"
        let hashtag = String(decoding: Data(hexString: "e697a5e69cace8aa9e")!, as: UTF8.self)
        // "héllo wörld 日本語 🚀 café" (é and ö NFC-precomposed)
        let content = String(
            decoding: Data(
                hexString:
                    "68c3a96c6c6f2077c3b6726c6420e697a5e69cace8aa9e20f09f9a8020636166c3a9"
            )!,
            as: UTF8.self
        )
        let unsigned = UnsignedEvent(
            pubkey: Self.pubkey1,
            createdAt: Self.timestamp,
            kind: 1,
            rawTags: [["t", hashtag]],
            content: content
        )

        // [0,"79be…1798",1700000000,1,[["t","日本語"]],"héllo wörld 日本語 🚀 café"]
        let expectedSerialization = Data(
            hexString:
                "5b302c2237396265363637656639646362626163353561303632393563653837306230373032396266636462326463"
                + "653238643935396632383135623136663831373938222c313730303030303030302c312c5b5b2274222c22e697a5e6"
                + "9cace8aa9e225d5d2c2268c3a96c6c6f2077c3b6726c6420e697a5e69cace8aa9e20f09f9a8020636166c3a9225d"
        )!

        #expect(try unsigned.serializedForHashing() == expectedSerialization)
        #expect(try unsigned.computedId == "273f93418df624cc93bc4d241e7c0b979797af75a38988ad38bb4d8ba199352b")
    }

    /// NIP-01's text mandates only the seven two-character escapes and says every other
    /// character is written verbatim, which read literally would put raw C0 control bytes in
    /// the serialization. No implementation does that: `JSON.stringify`, Python's `json`, and
    /// `serde_json` all emit `\uXXXX` with **lowercase** hex for the remaining controls, and
    /// that de-facto behaviour is what the ids on the network are built from. U+001B is in the
    /// vector deliberately: its escape contains a hex letter, so an uppercase-hex serializer
    /// (which agrees on U+0001) is caught here.
    @Test("control characters serialize as lowercase unicode escapes")
    func controlCharactersSerializeAsUnicodeEscapes() throws {
        let unsigned = UnsignedEvent(
            pubkey: Self.pubkey1,
            createdAt: Self.timestamp,
            kind: 1,
            rawTags: [],
            content: "ctrl:\u{01}\u{1B}!"
        )

        let serialized = try unsigned.serializedForHashing()
        let expectedSerialization =
            #"[0,"79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798","#
            + #"1700000000,1,[],"ctrl:\u0001\u001b!"]"#

        #expect(String(decoding: serialized, as: UTF8.self) == expectedSerialization)
        #expect(try unsigned.computedId == "25afcde11dc0bae511ce9811b35c7d5a59066aa0df373ffdd059849885583440")
    }

    /// Cross-implementation signature check. These signatures cannot be reproduced by signing
    /// in Swift: ``EventSigner/sign(_:)`` draws fresh auxiliary randomness on every call, so
    /// BIP-340 yields a different (equally valid) signature each time. Pinning them and
    /// verifying instead proves that an event signed by a different implementation over the
    /// same fields verifies here — i.e. that this client agrees with the network on which
    /// bytes get hashed and on the schnorr scheme applied to them.
    ///
    /// The id is asserted first, so a serialization break reports as a serialization break
    /// rather than as a mysterious signature failure.
    @Test("pinned bip-340 signatures verify", arguments: signatureVectors)
    func pinnedSignaturesVerify(_ vector: SignatureVector) throws {
        #expect(try vector.unsignedEvent.computedId == vector.id)
        #expect(try vector.event().verify())
    }

    /// A one-character change to the content must change the id. With the pinned id left in
    /// place the event is internally inconsistent, and ``Event/verify()`` must reject it
    /// before it ever reaches the signature check.
    @Test("tampering with content breaks the event id")
    func tamperingWithContentBreaksEventId() throws {
        let vector = Self.signatureVectors[0]
        let tamperedContent = vector.content + "!"
        let tamperedUnsigned = UnsignedEvent(
            pubkey: vector.pubkey,
            createdAt: vector.createdAt,
            kind: vector.kind,
            rawTags: vector.rawTags,
            content: tamperedContent
        )

        #expect(try tamperedUnsigned.computedId != vector.id)
        #expect(throws: NostrError.invalidEventId) {
            try vector.event(content: tamperedContent).verify()
        }
    }

    /// Corrupting the signature alone leaves the id consistent, so verification gets all the
    /// way to schnorr and must return `false` rather than throw.
    @Test("a corrupted signature fails verification")
    func corruptedSignatureFailsVerification() throws {
        let vector = Self.signatureVectors[0]
        // Flip the last hex digit deterministically, keeping the signature valid hex of the
        // right length so the failure comes from schnorr and not from decoding.
        let corruptedSig = vector.sig.dropLast() + (vector.sig.hasSuffix("0") ? "1" : "0")

        #expect(try vector.event(sig: String(corruptedSig)).verify() == false)
    }
}
