import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("GroupReference Tests (NIP-29)")
struct GroupReferenceTests {

    /// A valid 32-byte hex pubkey standing in for a group relay's key.
    private let relayPubkey = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"

    private func groupNAddr(
        identifier: String = "abcdef",
        kind: Int = 39000,
        relays: [String] = ["wss://groups.example.com"]
    ) throws -> NAddr {
        try NAddr(identifier: identifier, author: relayPubkey, kind: kind, relays: relays)
    }

    // MARK: - Building from an naddr

    @Test("a kind-39000 naddr maps to relay, id, and relay pubkey")
    func naddrRoundTrip() throws {
        let naddr = try groupNAddr(relays: ["wss://groups.example.com", "wss://mirror.example.com"])
        let reference = try GroupReference(naddr: naddr)

        #expect(reference.relayURL == "wss://groups.example.com")
        #expect(reference.id == "abcdef")
        #expect(reference.relayPubkey == relayPubkey)
        #expect(reference.inviteCode == nil)

        let invited = try GroupReference(naddr: naddr, inviteCode: "A7fjq2")
        #expect(invited.inviteCode == "A7fjq2")
    }

    @Test("an naddr of any other kind is rejected")
    func rejectsWrongKind() throws {
        let naddr = try groupNAddr(kind: 30023)
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try GroupReference(naddr: naddr)
        }
    }

    @Test("an naddr without a usable relay hint is rejected")
    func rejectsMissingRelayHints() throws {
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try GroupReference(naddr: self.groupNAddr(relays: []))
        }
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try GroupReference(naddr: self.groupNAddr(relays: [""]))
        }
    }

    @Test("the first non-empty relay hint wins")
    func skipsEmptyRelayHints() throws {
        let naddr = try groupNAddr(relays: ["", "wss://groups.example.com"])
        #expect(try GroupReference(naddr: naddr).relayURL == "wss://groups.example.com")
    }

    // MARK: - Share-link strings

    @Test("a bare naddr string parses without an invite code")
    func parsesNaddrString() throws {
        let reference = try GroupReference(naddrString: try groupNAddr().encoded)

        #expect(reference.relayURL == "wss://groups.example.com")
        #expect(reference.id == "abcdef")
        #expect(reference.relayPubkey == relayPubkey)
        #expect(reference.inviteCode == nil)
    }

    @Test("an ?invite= suffix is split off and captured")
    func parsesInviteSuffix() throws {
        let reference = try GroupReference(naddrString: try groupNAddr().encoded + "?invite=A7fjq2")

        #expect(reference.id == "abcdef")
        #expect(reference.inviteCode == "A7fjq2")
    }

    @Test("a percent-encoded invite code is decoded")
    func decodesPercentEncodedInvite() throws {
        let reference = try GroupReference(naddrString: try groupNAddr().encoded + "?invite=a%2Fb%20c")
        #expect(reference.inviteCode == "a/b c")
    }

    @Test("an invalidly encoded query falls back to the raw invite value")
    func keepsRawInviteWhenQueryDoesNotParse() throws {
        let reference = try GroupReference(naddrString: try groupNAddr().encoded + "?invite=a%ZZ")
        #expect(reference.inviteCode == "a%ZZ")
    }

    @Test("an empty or absent invite parameter yields no code")
    func emptyInviteIsNil() throws {
        let encoded = try groupNAddr().encoded
        #expect(try GroupReference(naddrString: encoded + "?invite=").inviteCode == nil)
        #expect(try GroupReference(naddrString: encoded + "?foo=bar").inviteCode == nil)
    }

    // MARK: - Emitting an naddr

    @Test("naddr() requires the relay pubkey")
    func naddrRequiresRelayPubkey() throws {
        let reference = GroupReference(relayURL: "wss://groups.example.com", id: "abcdef")
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try reference.naddr()
        }
        #expect(throws: NostrError.invalidNIP19Entity) {
            _ = try reference.shareableString()
        }
    }

    @Test("naddr() rebuilds the group coordinate")
    func naddrRebuildsCoordinate() throws {
        let reference = GroupReference(
            relayURL: "wss://groups.example.com", id: "abcdef", relayPubkey: relayPubkey)
        let naddr = try reference.naddr()

        #expect(naddr.identifier == "abcdef")
        #expect(naddr.author == relayPubkey)
        #expect(naddr.kind == 39000)
        #expect(naddr.relays == ["wss://groups.example.com"])
    }

    @Test("shareableString() round-trips through init(naddrString:), invite code included")
    func shareableStringRoundTrips() throws {
        let reference = GroupReference(
            relayURL: "wss://groups.example.com",
            id: "abcdef",
            relayPubkey: relayPubkey,
            inviteCode: "top/secret code+1"
        )
        let shared = try reference.shareableString()

        #expect(shared.hasPrefix("naddr1"))
        #expect(shared.contains("?invite="))
        #expect(try GroupReference(naddrString: shared) == reference)

        let bare = GroupReference(relayURL: "wss://groups.example.com", id: "abcdef", relayPubkey: relayPubkey)
        #expect(try GroupReference(naddrString: bare.shareableString()) == bare)
    }

    // MARK: - Memberwise storage

    @Test("the memberwise initializer stores every field")
    func memberwiseInitPassthrough() {
        let reference = GroupReference(
            relayURL: "wss://groups.example.com",
            id: "abcdef",
            relayPubkey: relayPubkey,
            inviteCode: "A7fjq2"
        )

        #expect(reference.relayURL == "wss://groups.example.com")
        #expect(reference.id == "abcdef")
        #expect(reference.relayPubkey == relayPubkey)
        #expect(reference.inviteCode == "A7fjq2")

        let minimal = GroupReference(relayURL: "wss://groups.example.com", id: "abcdef")
        #expect(minimal.relayPubkey == nil)
        #expect(minimal.inviteCode == nil)
    }
}
