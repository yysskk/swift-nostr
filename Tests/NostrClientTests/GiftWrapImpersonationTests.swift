import Foundation
import NostrCore
import Testing

@testable import NostrClient

/// NIP-17 states the rule plainly: "Clients MUST verify if pubkey of the kind:13 is the same pubkey
/// on the kind:14, otherwise any sender can impersonate others by simply changing the pubkey on
/// kind:14." The seal is signed and so proves who sent it, but the rumor inside is unsigned by
/// design — nothing about it is attested except by the seal that carries it.
/// https://github.com/nostr-protocol/nips/blob/master/17.md
@Suite("Gift Wrap Sender Authentication Tests")
struct GiftWrapImpersonationTests {

    /// Builds the rumor JSON exactly as `GiftWrap` writes it, so the forgery differs from a genuine
    /// message only in the fields under test.
    private func rumorJSON(
        id: String,
        publicKey: String,
        createdAt: Int64,
        kind: Event.Kind,
        tags: [[String]],
        content: String
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "pubkey": publicKey,
            "created_at": createdAt,
            "kind": kind.rawValue,
            "tags": tags,
            "content": content,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    /// Seals `rumorJSON` as `sender` and wraps it for `recipient` with a fresh ephemeral key —
    /// the same construction `GiftWrap.wrap` performs, but over a rumor chosen by the caller.
    /// `sealKind` and `alterSeal` let a test break the seal itself.
    private func wrap(
        rumorJSON: String,
        sender: KeyPair,
        recipientPublicKey: PublicKey,
        sealKind: Event.Kind = .seal,
        alterSeal: (Event) throws -> Event = { $0 }
    ) throws -> Event {
        let senderSigner = EventSigner(keyPair: sender)
        let seal = try alterSeal(
            senderSigner.sign(
                UnsignedEvent(
                    publicKey: sender.publicKey,
                    createdAt: Timestamp(rawValue: Timestamp.now.rawValue - 60),
                    kind: sealKind,
                    tags: [],
                    content: try senderSigner.nip44Encrypt(rumorJSON, to: recipientPublicKey)
                )
            )
        )

        let sealJSON = String(decoding: try JSONEncoder().encode(seal), as: UTF8.self)
        let ephemeral = EventSigner(keyPair: try KeyPair())
        return try ephemeral.sign(
            UnsignedEvent(
                publicKey: ephemeral.publicKey,
                createdAt: Timestamp(rawValue: Timestamp.now.rawValue - 60),
                kind: .giftWrap,
                tags: [Tag.publicKey(recipientPublicKey)],
                content: try ephemeral.nip44Encrypt(sealJSON, to: recipientPublicKey)
            )
        )
    }

    /// Mallory seals a rumor that names Alice as its author. The seal's own signature is Mallory's
    /// and verifies, so signature checking alone does not catch this — only comparing the two
    /// public keys does. The rumor even carries the correct hash of its own contents, so an id check
    /// does not catch it either.
    @Test("a rumor attributed to someone other than the sealer is rejected")
    func rumorFromAnotherAuthorIsRejected() async throws {
        let mallory = try KeyPair()
        let alice = try KeyPair()
        let bob = try KeyPair()

        let forged = UnsignedEvent(
            publicKey: alice.publicKey,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .privateDirectMessage,
            rawTags: [["p", bob.publicKey.hex]],
            content: "I approve this transfer"
        )
        let rumor = try rumorJSON(
            id: try forged.computedID.hex,
            publicKey: alice.publicKey.hex,
            createdAt: forged.createdAt.rawValue,
            kind: forged.kind,
            tags: forged.tags,
            content: forged.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: mallory, recipientPublicKey: bob.publicKey)

        await #expect(throws: GiftWrap.Error.authorMismatch) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    /// The rumor's id is the key `DirectMessage` and `DirectMessageReaction` correlate on, and it
    /// arrives unsigned from the counterparty. Recomputing it keeps a sender from choosing an id
    /// that collides with another conversation's message or overwrites a stored one.
    @Test("a rumor whose id is not the hash of its contents is rejected")
    func rumorWithForgedIDIsRejected() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let rumor = try rumorJSON(
            id: try EventID(hex: String(repeating: "11", count: 32)).hex,
            publicKey: alice.publicKey.hex,
            createdAt: 1_700_000_000,
            kind: .privateDirectMessage,
            tags: [["p", bob.publicKey.hex]],
            content: "hello"
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: alice, recipientPublicKey: bob.publicKey)

        await #expect(throws: GiftWrap.Error.invalidRumorID) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    /// The check is on the public keys, not on the rumor being a DM: a mismatch has to fail whatever
    /// kind it claims to be, since gift wrapping carries reactions and file messages too.
    @Test("the author check applies to any wrapped kind")
    func mismatchIsRejectedForOtherKinds() async throws {
        let mallory = try KeyPair()
        let alice = try KeyPair()
        let bob = try KeyPair()

        let forged = UnsignedEvent(
            publicKey: alice.publicKey,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .reaction,
            rawTags: [["p", bob.publicKey.hex]],
            content: "+"
        )
        let rumor = try rumorJSON(
            id: try forged.computedID.hex,
            publicKey: alice.publicKey.hex,
            createdAt: forged.createdAt.rawValue,
            kind: forged.kind,
            tags: forged.tags,
            content: forged.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: mallory, recipientPublicKey: bob.publicKey)

        await #expect(throws: GiftWrap.Error.authorMismatch) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    @Test("an event that is not a gift wrap is rejected with its kind")
    func nonGiftWrapIsRejected() async throws {
        let bob = try KeyPair()
        let note = try EventSigner(keyPair: try KeyPair()).sign(.textNote("hello"))

        await #expect(throws: GiftWrap.Error.unexpectedKind(.textNote)) {
            try await GiftWrap.unwrap(giftWrap: note, recipient: EventSigner(keyPair: bob))
        }
    }

    @Test("a gift wrap whose seal is not kind 13 is rejected with the seal's kind")
    func nonSealLayerIsRejected() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let giftWrap = try wrap(
            rumorJSON: "{}", sender: alice, recipientPublicKey: bob.publicKey, sealKind: .textNote)

        await #expect(throws: GiftWrap.Error.unexpectedKind(.textNote)) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    @Test("a seal whose signature does not verify is rejected")
    func sealWithForeignSignatureIsRejected() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        // A valid signature, but over another event's id.
        let foreignSignature = try EventSigner(keyPair: alice).sign(.textNote("other")).signature
        let giftWrap = try wrap(rumorJSON: "{}", sender: alice, recipientPublicKey: bob.publicKey) { seal in
            Event(
                id: seal.id, publicKey: seal.publicKey, createdAt: seal.createdAt, kind: seal.kind,
                tags: seal.tags, content: seal.content, signature: foreignSignature)
        }

        await #expect(throws: GiftWrap.Error.invalidSealSignature) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    /// The genuine path built by the same helper, confirming the forgeries above differ from a real
    /// message only in the public key and id — and that the new checks do not reject honest traffic.
    @Test("a rumor sealed by its own author still unwraps")
    func genuineMessageStillUnwraps() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let event = UnsignedEvent(
            publicKey: alice.publicKey,
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .privateDirectMessage,
            rawTags: [["p", bob.publicKey.hex]],
            content: "hello"
        )
        let rumor = try rumorJSON(
            id: try event.computedID.hex,
            publicKey: alice.publicKey.hex,
            createdAt: event.createdAt.rawValue,
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: alice, recipientPublicKey: bob.publicKey)
        let unwrapped = try await GiftWrap.unwrap(
            giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPublicKey == alice.publicKey)
        #expect(unwrapped.event.publicKey == alice.publicKey)
        #expect(unwrapped.event.content == "hello")
    }

    /// `GiftWrap.wrap` must keep producing messages `unwrap` accepts.
    @Test("a message built by wrap round-trips through unwrap")
    func wrapUnwrapRoundTrip() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let signer = EventSigner(keyPair: alice)

        let original = try signer.sign(.textNote("Secret message"))
        let giftWrap = try await GiftWrap.wrap(
            event: original, signer: signer, recipientPublicKey: bob.publicKey)
        let unwrapped = try await GiftWrap.unwrap(
            giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPublicKey == alice.publicKey)
        #expect(unwrapped.event.publicKey == alice.publicKey)
        #expect(unwrapped.event.id == original.id)
        #expect(unwrapped.event.content == "Secret message")
    }
}
