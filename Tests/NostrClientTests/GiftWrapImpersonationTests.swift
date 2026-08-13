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
        pubkey: String,
        createdAt: Int64,
        kind: Event.Kind,
        tags: [[String]],
        content: String
    ) throws -> String {
        let object: [String: Any] = [
            "id": id,
            "pubkey": pubkey,
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
    private func wrap(
        rumorJSON: String,
        sender: KeyPair,
        recipientPubkey: String
    ) throws -> Event {
        let senderSigner = EventSigner(keyPair: sender)
        let seal = try senderSigner.sign(
            UnsignedEvent(
                pubkey: sender.publicKeyHex,
                createdAt: Int64(Date().timeIntervalSince1970) - 60,
                kind: .seal,
                tags: [],
                content: try senderSigner.nip44Encrypt(rumorJSON, to: recipientPubkey)
            )
        )

        let sealJSON = String(decoding: try JSONEncoder().encode(seal), as: UTF8.self)
        let ephemeral = EventSigner(keyPair: try KeyPair())
        return try ephemeral.sign(
            UnsignedEvent(
                pubkey: ephemeral.publicKey,
                createdAt: Int64(Date().timeIntervalSince1970) - 60,
                kind: .giftWrap,
                tags: [Tag.pubkey(recipientPubkey)],
                content: try ephemeral.nip44Encrypt(sealJSON, to: recipientPubkey)
            )
        )
    }

    /// Mallory seals a rumor that names Alice as its author. The seal's own signature is Mallory's
    /// and verifies, so signature checking alone does not catch this — only comparing the two
    /// pubkeys does. The rumor even carries the correct hash of its own contents, so an id check
    /// does not catch it either.
    @Test("a rumor attributed to someone other than the sealer is rejected")
    func rumorFromAnotherAuthorIsRejected() async throws {
        let mallory = try KeyPair()
        let alice = try KeyPair()
        let bob = try KeyPair()

        let forged = UnsignedEvent(
            pubkey: alice.publicKeyHex,
            createdAt: 1_700_000_000,
            kind: .privateDirectMessage,
            rawTags: [["p", bob.publicKeyHex]],
            content: "I approve this transfer"
        )
        let rumor = try rumorJSON(
            id: try forged.computedId,
            pubkey: alice.publicKeyHex,
            createdAt: forged.createdAt,
            kind: forged.kind,
            tags: forged.tags,
            content: forged.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: mallory, recipientPubkey: bob.publicKeyHex)

        await #expect(throws: NostrError.verificationFailed) {
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
            id: String(repeating: "11", count: 32),
            pubkey: alice.publicKeyHex,
            createdAt: 1_700_000_000,
            kind: .privateDirectMessage,
            tags: [["p", bob.publicKeyHex]],
            content: "hello"
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: alice, recipientPubkey: bob.publicKeyHex)

        await #expect(throws: NostrError.invalidEventId) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    /// The check is on the pubkeys, not on the rumor being a DM: a mismatch has to fail whatever
    /// kind it claims to be, since gift wrapping carries reactions and file messages too.
    @Test("the author check applies to any wrapped kind")
    func mismatchIsRejectedForOtherKinds() async throws {
        let mallory = try KeyPair()
        let alice = try KeyPair()
        let bob = try KeyPair()

        let forged = UnsignedEvent(
            pubkey: alice.publicKeyHex,
            createdAt: 1_700_000_000,
            kind: .reaction,
            rawTags: [["p", bob.publicKeyHex]],
            content: "+"
        )
        let rumor = try rumorJSON(
            id: try forged.computedId,
            pubkey: alice.publicKeyHex,
            createdAt: forged.createdAt,
            kind: forged.kind,
            tags: forged.tags,
            content: forged.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: mallory, recipientPubkey: bob.publicKeyHex)

        await #expect(throws: NostrError.verificationFailed) {
            try await GiftWrap.unwrap(giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))
        }
    }

    /// The genuine path built by the same helper, confirming the forgeries above differ from a real
    /// message only in the pubkey and id — and that the new checks do not reject honest traffic.
    @Test("a rumor sealed by its own author still unwraps")
    func genuineMessageStillUnwraps() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()

        let event = UnsignedEvent(
            pubkey: alice.publicKeyHex,
            createdAt: 1_700_000_000,
            kind: .privateDirectMessage,
            rawTags: [["p", bob.publicKeyHex]],
            content: "hello"
        )
        let rumor = try rumorJSON(
            id: try event.computedId,
            pubkey: alice.publicKeyHex,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content
        )

        let giftWrap = try wrap(rumorJSON: rumor, sender: alice, recipientPubkey: bob.publicKeyHex)
        let unwrapped = try await GiftWrap.unwrap(
            giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPubkey == alice.publicKeyHex)
        #expect(unwrapped.event.pubkey == alice.publicKeyHex)
        #expect(unwrapped.event.content == "hello")
    }

    /// `GiftWrap.wrap` must keep producing messages `unwrap` accepts.
    @Test("a message built by wrap round-trips through unwrap")
    func wrapUnwrapRoundTrip() async throws {
        let alice = try KeyPair()
        let bob = try KeyPair()
        let signer = EventSigner(keyPair: alice)

        let original = try signer.signTextNote(content: "Secret message")
        let giftWrap = try await GiftWrap.wrap(
            event: original, signer: signer, recipientPubkey: bob.publicKeyHex)
        let unwrapped = try await GiftWrap.unwrap(
            giftWrap: giftWrap, recipient: EventSigner(keyPair: bob))

        #expect(unwrapped.senderPubkey == alice.publicKeyHex)
        #expect(unwrapped.event.pubkey == alice.publicKeyHex)
        #expect(unwrapped.event.id == original.id)
        #expect(unwrapped.event.content == "Secret message")
    }
}
