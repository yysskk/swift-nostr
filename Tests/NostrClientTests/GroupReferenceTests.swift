import Foundation
import NostrCore
import Testing

@testable import NostrClient

@Suite("GroupReference Tests (NIP-29)")
struct GroupReferenceTests {

    /// A valid 32-byte hex public key standing in for a group relay's key.
    private let relayPublicKey = try! PublicKey(hex: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d")

    private func groupNAddr(
        identifier: String = "abcdef",
        kind: Event.Kind = 39000,
        relays: [RelayURL] = [RelayURL("wss://groups.example.com")!]
    ) throws -> NAddr {
        try NAddr(identifier: identifier, author: relayPublicKey, kind: kind, relays: relays)
    }

    // MARK: - Building from an naddr

    @Test("a kind-39000 naddr maps to relay, id, and relay public key")
    func naddrRoundTrip() throws {
        let naddr = try groupNAddr(relays: [
            RelayURL("wss://groups.example.com")!, RelayURL("wss://mirror.example.com")!,
        ])
        let reference = try GroupReference(naddr: naddr)

        #expect(reference.relayURL == RelayURL("wss://groups.example.com"))
        #expect(reference.id == "abcdef")
        #expect(reference.relayPublicKey == relayPublicKey)
        #expect(reference.inviteCode == nil)

        let invited = try GroupReference(naddr: naddr, inviteCode: "A7fjq2")
        #expect(invited.inviteCode == "A7fjq2")
    }

    @Test("an naddr of any other kind is rejected")
    func rejectsWrongKind() throws {
        let naddr = try groupNAddr(kind: 30023)
        #expect(throws: GroupReference.Error.unexpectedKind(.longFormContent)) {
            _ = try GroupReference(naddr: naddr)
        }
    }

    /// An `naddr` string for the group whose relay hints are written as `relays`, verbatim.
    private func rawGroupNAddr(relays: [String]) throws -> String {
        try RawTLV.bech32(
            prefix: "naddr", special: Data("abcdef".utf8), relays: relays, author: relayPublicKey, kind: 39000)
    }

    @Test("an naddr without a valid relay hint is rejected")
    func rejectsMissingRelayHints() throws {
        #expect(throws: GroupReference.Error.missingRelay) {
            _ = try GroupReference(naddr: self.groupNAddr(relays: []))
        }
        let malformedOnly = try rawGroupNAddr(relays: ["", "https://groups.example.com"])
        #expect(throws: GroupReference.Error.missingRelay) {
            _ = try GroupReference(naddrString: malformedOnly)
        }
    }

    @Test("a share link that is not an naddr is rejected as an invalid coordinate")
    func rejectsUndecodableCoordinate() throws {
        let nprofile = try NProfile(publicKey: relayPublicKey).encoded
        #expect(throws: GroupReference.Error.invalidCoordinate(.unexpectedPrefix("nprofile"))) {
            _ = try GroupReference(naddrString: nprofile + "?invite=A7fjq2")
        }
    }

    @Test("the first valid relay hint wins")
    func skipsMalformedRelayHints() throws {
        let naddr = try rawGroupNAddr(relays: ["", "not a relay", "WSS://Groups.Example.com/"])
        #expect(try GroupReference(naddrString: naddr).relayURL == RelayURL("wss://groups.example.com"))
    }

    // MARK: - Share-link strings

    @Test("a bare naddr string parses without an invite code")
    func parsesNaddrString() throws {
        let reference = try GroupReference(naddrString: try groupNAddr().encoded)

        #expect(reference.relayURL == RelayURL("wss://groups.example.com"))
        #expect(reference.id == "abcdef")
        #expect(reference.relayPublicKey == relayPublicKey)
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

    @Test("naddr() requires the relay public key")
    func naddrRequiresRelayPublicKey() throws {
        let reference = GroupReference(relayURL: RelayURL("wss://groups.example.com")!, id: "abcdef")
        #expect(throws: GroupReference.Error.unknownRelayPublicKey) {
            _ = try reference.naddr()
        }
        #expect(throws: GroupReference.Error.unknownRelayPublicKey) {
            _ = try reference.shareableString()
        }
    }

    @Test("naddr() rebuilds the group coordinate")
    func naddrRebuildsCoordinate() throws {
        let reference = GroupReference(
            relayURL: RelayURL("wss://groups.example.com")!, id: "abcdef", relayPublicKey: relayPublicKey)
        let naddr = try reference.naddr()

        #expect(naddr.identifier == "abcdef")
        #expect(naddr.author == relayPublicKey)
        #expect(naddr.kind == 39000)
        #expect(naddr.relays == [RelayURL("wss://groups.example.com")!])
    }

    @Test("shareableString() round-trips through init(naddrString:), invite code included")
    func shareableStringRoundTrips() throws {
        let reference = GroupReference(
            relayURL: RelayURL("wss://groups.example.com")!,
            id: "abcdef",
            relayPublicKey: relayPublicKey,
            inviteCode: "top/secret code+1"
        )
        let shared = try reference.shareableString()

        #expect(shared.hasPrefix("naddr1"))
        #expect(shared.contains("?invite="))
        #expect(try GroupReference(naddrString: shared) == reference)

        let bare = GroupReference(
            relayURL: RelayURL("wss://groups.example.com")!, id: "abcdef", relayPublicKey: relayPublicKey)
        #expect(try GroupReference(naddrString: bare.shareableString()) == bare)
    }

    // MARK: - Memberwise storage

    @Test("the memberwise initializer stores every field")
    func memberwiseInitPassthrough() {
        let reference = GroupReference(
            relayURL: RelayURL("wss://groups.example.com")!,
            id: "abcdef",
            relayPublicKey: relayPublicKey,
            inviteCode: "A7fjq2"
        )

        #expect(reference.relayURL == RelayURL("wss://groups.example.com"))
        #expect(reference.id == "abcdef")
        #expect(reference.relayPublicKey == relayPublicKey)
        #expect(reference.inviteCode == "A7fjq2")

        let minimal = GroupReference(relayURL: RelayURL("wss://groups.example.com")!, id: "abcdef")
        #expect(minimal.relayPublicKey == nil)
        #expect(minimal.inviteCode == nil)
    }
}
