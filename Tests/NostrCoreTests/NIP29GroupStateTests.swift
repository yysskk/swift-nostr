import Foundation
import NostrCore
import NostrTestSupport
import Testing

/// Signs a relay-generated group state event carrying `tags` at a pinned timestamp.
private func stateEvent(
    kind: Event.Kind,
    tags: [Event.Tag],
    signer: EventSigner,
    createdAt: Timestamp = Timestamp(rawValue: 1_700_000_000)
) throws -> Event {
    try signer.sign(
        UnsignedEvent(
            publicKey: signer.publicKey, createdAt: createdAt, kind: kind, tags: tags, content: ""))
}

/// One (kind, parser) pair per relay-generated state model, so the shared validation
/// paths are exercised uniformly across all five parsers.
private let stateParsers: [(kind: Event.Kind, parse: @Sendable (Event, PublicKey?) throws -> Void)] = [
    (.groupMetadata, { _ = try Groups.Metadata(event: $0, relayPublicKey: $1) }),
    (.groupAdmins, { _ = try Groups.AdminList(event: $0, relayPublicKey: $1) }),
    (.groupMembers, { _ = try Groups.MemberList(event: $0, relayPublicKey: $1) }),
    (.groupRoles, { _ = try Groups.RoleList(event: $0, relayPublicKey: $1) }),
    (.groupPinList, { _ = try Groups.PinList(event: $0, relayPublicKey: $1) }),
]

@Suite("NIP-29 Group State")
struct NIP29GroupStateTests {

    // MARK: Metadata

    @Test("metadata with every field set round-trips through its wire tags")
    func metadataRoundTrip() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let metadata = Groups.Metadata(
            groupID: "abcdef",
            name: "Pizza Lovers",
            picture: "https://pizza.com/pizza.png",
            banner: "https://pizza.com/banner.png",
            about: "a group for people who love pizza",
            isPrivate: true,
            isRestricted: true,
            isHidden: true,
            isClosed: true,
            isLiveKitEnabled: true,
            supportedKinds: [.chatMessage, .thread],
            parentGroupID: "communities",
            childGroupIDs: ["pineapple", "margherita"],
            additionalTags: [Event.Tag(name: "alt", values: ["pizza group"])]
        )

        let event = try stateEvent(kind: .groupMetadata, tags: metadata.tags, signer: relay)

        #expect(try Groups.Metadata(event: event) == metadata)
    }

    @Test("a metadata event with only a d tag parses to the defaults")
    func metadataDefaults() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let event = try stateEvent(kind: .groupMetadata, tags: [.identifier("abcdef")], signer: relay)

        let parsed = try Groups.Metadata(event: event)

        #expect(parsed == Groups.Metadata(groupID: "abcdef"))
        #expect(parsed.name == nil)
        #expect(parsed.picture == nil)
        #expect(parsed.banner == nil)
        #expect(parsed.about == nil)
        #expect(!parsed.isPrivate)
        #expect(!parsed.isRestricted)
        #expect(!parsed.isHidden)
        #expect(!parsed.isClosed)
        #expect(!parsed.isLiveKitEnabled)
        #expect(parsed.supportedKinds == nil)
        #expect(parsed.parentGroupID == nil)
        #expect(parsed.childGroupIDs.isEmpty)
        #expect(parsed.additionalTags.isEmpty)
    }

    @Test("explicit public and open tags parse to false flags and are consumed")
    func metadataExplicitPublicOpen() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let event = try stateEvent(
            kind: .groupMetadata,
            tags: [.identifier("abcdef"), Event.Tag(name: "public"), Event.Tag(name: "open")],
            signer: relay
        )

        let parsed = try Groups.Metadata(event: event)

        #expect(!parsed.isPrivate)
        #expect(!parsed.isClosed)
        #expect(parsed.additionalTags.isEmpty)
    }

    @Test("fieldTags emits the visibility pairs, true-only flags, and never the d tag")
    func metadataFieldTags() {
        let open = Groups.Metadata(groupID: "abcdef")
        #expect(open.fieldTags.map(\.rawArray) == [["public"], ["open"]])

        let flagged = Groups.Metadata(
            groupID: "abcdef",
            isPrivate: true,
            isRestricted: true,
            isHidden: true,
            isClosed: true,
            isLiveKitEnabled: true
        )
        #expect(
            flagged.fieldTags.map(\.rawArray)
                == [["private"], ["closed"], ["restricted"], ["hidden"], ["livekit"]])
        #expect(flagged.fieldTags.allSatisfy { $0.name != "d" })
        #expect(flagged.tags.first == .identifier("abcdef"))
    }

    @Test("supported_kinds distinguishes absent from empty and drops junk values")
    func metadataSupportedKinds() throws {
        let relay = EventSigner(keyPair: KeyPair())

        let absent = try stateEvent(kind: .groupMetadata, tags: [.identifier("abcdef")], signer: relay)
        #expect(try Groups.Metadata(event: absent).supportedKinds == nil)

        let empty = try stateEvent(
            kind: .groupMetadata,
            tags: [.identifier("abcdef"), Event.Tag(name: "supported_kinds")],
            signer: relay
        )
        #expect(try Groups.Metadata(event: empty).supportedKinds == [])

        let junk = try stateEvent(
            kind: .groupMetadata,
            tags: [.identifier("abcdef"), Event.Tag(name: "supported_kinds", values: ["9", "pizza", "11"])],
            signer: relay
        )
        #expect(try Groups.Metadata(event: junk).supportedKinds == [.chatMessage, .thread])
    }

    @Test("unknown tags round-trip through additionalTags in order")
    func metadataUnknownTags() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let event = try stateEvent(
            kind: .groupMetadata,
            tags: [
                .identifier("abcdef"),
                Event.Tag(name: "alt", values: ["pizza group"]),
                Event.Tag(name: "name", values: ["Pizza Lovers"]),
                Event.Tag(name: "custom", values: ["a", "b"]),
            ],
            signer: relay
        )

        let parsed = try Groups.Metadata(event: event)
        #expect(parsed.additionalTags.map(\.rawArray) == [["alt", "pizza group"], ["custom", "a", "b"]])

        let reemitted = try stateEvent(kind: .groupMetadata, tags: parsed.tags, signer: relay)
        #expect(try Groups.Metadata(event: reemitted) == parsed)
    }

    @Test("the spec's kind-39000 example layout parses field by field")
    func specMetadataExample() throws {
        // A parse-only event literal with a dummy id and signature, mirroring the NIP-98
        // spec-vector precedent: the spec example carries no consistent signature, and
        // the parsers never verify one.
        let event = Event(
            id: try EventID(hex: String(repeating: "0", count: 64)),
            publicKey: try PublicKey(hex: String(repeating: "b", count: 64)),
            createdAt: Timestamp(rawValue: 1_700_000_000),
            kind: .groupMetadata,
            tags: [
                ["d", "<id>"],
                ["name", "Pizza Lovers"],
                ["picture", "https://pizza.com/pizza.png"],
                ["banner", "https://pizza.com/banner.png"],
                ["about", "a group for people who love pizza"],
                ["private"],
                ["closed"],
                ["supported_kinds", "9", "11"],
            ].map(Event.Tag.init(rawArray:)),
            content: "",
            signature: nil
        )

        let metadata = try Groups.Metadata(event: event)

        #expect(metadata.groupID == "<id>")
        #expect(metadata.name == "Pizza Lovers")
        #expect(metadata.picture == "https://pizza.com/pizza.png")
        #expect(metadata.banner == "https://pizza.com/banner.png")
        #expect(metadata.about == "a group for people who love pizza")
        #expect(metadata.isPrivate)
        #expect(metadata.isClosed)
        #expect(!metadata.isRestricted)
        #expect(!metadata.isHidden)
        #expect(!metadata.isLiveKitEnabled)
        #expect(metadata.supportedKinds == [.chatMessage, .thread])
        #expect(metadata.parentGroupID == nil)
        #expect(metadata.childGroupIDs.isEmpty)
        #expect(metadata.additionalTags.isEmpty)
    }

    // MARK: Admins, Members, Roles, and Pins

    @Test("an admin list with multi-role and role-less admins round-trips")
    func adminListRoundTrip() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let ceo = PublicKey.fixture("ceo")
        let greeter = PublicKey.fixture("greeter")
        let list = Groups.AdminList(
            groupID: "abcdef",
            admins: [
                Groups.Admin(publicKey: ceo, roles: ["ceo", "admin"]),
                Groups.Admin(publicKey: greeter),
            ]
        )

        #expect(
            list.tags.map(\.rawArray)
                == [["d", "abcdef"], ["p", ceo.hex, "ceo", "admin"], ["p", greeter.hex]])

        let event = try stateEvent(kind: .groupAdmins, tags: list.tags, signer: relay)
        #expect(try Groups.AdminList(event: event) == list)
    }

    @Test("a member list round-trips with order preserved")
    func memberListRoundTrip() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let members = [PublicKey.fixture("first"), PublicKey.fixture("second")]
        let list = Groups.MemberList(groupID: "abcdef", members: members)

        #expect(list.tags.map(\.rawArray) == [["d", "abcdef"], ["p", members[0].hex], ["p", members[1].hex]])

        let event = try stateEvent(kind: .groupMembers, tags: list.tags, signer: relay)
        #expect(try Groups.MemberList(event: event) == list)
    }

    @Test("a role list round-trips with and without descriptions")
    func roleListRoundTrip() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let list = Groups.RoleList(
            groupID: "abcdef",
            roles: [
                Groups.Role(name: "ceo", description: "Can do everything"),
                Groups.Role(name: "member"),
            ]
        )

        #expect(
            list.tags.map(\.rawArray)
                == [["d", "abcdef"], ["role", "ceo", "Can do everything"], ["role", "member"]])

        let event = try stateEvent(kind: .groupRoles, tags: list.tags, signer: relay)
        #expect(try Groups.RoleList(event: event) == list)
    }

    @Test("a pin list preserves the exact order of interleaved e and a items")
    func pinListRoundTrip() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let first = EventID.fixture("first")
        let second = EventID.fixture("second")
        let address = "39000:\(String(repeating: "b", count: 64)):abcdef"
        let list = Groups.PinList(
            groupID: "abcdef",
            items: [.event(id: first), .address(address), .event(id: second)]
        )

        #expect(
            list.tags.map(\.rawArray)
                == [["d", "abcdef"], ["e", first.hex], ["a", address], ["e", second.hex]])

        let event = try stateEvent(kind: .groupPinList, tags: list.tags, signer: relay)
        let parsed = try Groups.PinList(event: event)
        #expect(parsed == list)
        #expect(parsed.items == [.event(id: first), .address(address), .event(id: second)])
    }

    /// State events come from the group's relay, so a "p" or "e" value that is not a canonical key
    /// or id is dropped while the well-formed entries around it are kept.
    @Test("admin, member, and pin lists skip entries whose key or id is malformed")
    func listsSkipMalformedEntries() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let member = PublicKey.fixture("member")
        let pinned = EventID.fixture("pinned")
        let malformed = ["not-a-key", member.hex.uppercased(), String(member.hex.dropLast())]

        let admins = try stateEvent(
            kind: .groupAdmins,
            tags: [.identifier("abcdef")] + malformed.map { Event.Tag(name: "p", values: [$0, "ceo"]) }
                + [.publicKey(member, roles: ["admin"])],
            signer: relay)
        #expect(try Groups.AdminList(event: admins).admins == [Groups.Admin(publicKey: member, roles: ["admin"])])

        let members = try stateEvent(
            kind: .groupMembers,
            tags: [.identifier("abcdef")] + malformed.map { Event.Tag(name: "p", values: [$0]) } + [.publicKey(member)],
            signer: relay)
        #expect(try Groups.MemberList(event: members).members == [member])

        let pins = try stateEvent(
            kind: .groupPinList,
            tags: [.identifier("abcdef"), Event.Tag(name: .event, values: ["not-an-id"]), .event(pinned)], signer: relay
        )
        #expect(try Groups.PinList(event: pins).items == [.event(id: pinned)])
    }

    // MARK: Validation

    @Test("every parser rejects an event of the wrong kind with the expected payloads")
    func wrongKind() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let note = try stateEvent(kind: .textNote, tags: [.identifier("abcdef")], signer: relay)

        for (kind, parse) in stateParsers {
            #expect(throws: Groups.ValidationError.invalidEventKind(expected: kind, actual: .textNote)) {
                try parse(note, nil)
            }
        }
    }

    @Test("every parser rejects a missing d tag and an empty d value")
    func missingGroupID() throws {
        let relay = EventSigner(keyPair: KeyPair())

        for (kind, parse) in stateParsers {
            let missing = try stateEvent(kind: kind, tags: [], signer: relay)
            #expect(throws: Groups.ValidationError.missingGroupID(kind)) { try parse(missing, nil) }

            let empty = try stateEvent(kind: kind, tags: [.identifier("")], signer: relay)
            #expect(throws: Groups.ValidationError.missingGroupID(kind)) { try parse(empty, nil) }
        }
    }

    @Test("parse failures are thrown as the concrete ValidationError")
    func typedValidationError() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let impostor = EventSigner(keyPair: KeyPair())
        let forged = try stateEvent(kind: .groupMetadata, tags: [.identifier("abcdef")], signer: impostor)

        do {
            _ = try Groups.Metadata(event: forged, relayPublicKey: relay.publicKey)
            Issue.record("Expected an unexpected author")
        } catch {
            #expect(error == .unexpectedAuthor(expected: relay.publicKey, actual: impostor.publicKey))
        }
    }

    @Test("every parser pins the author when a relay public key is given")
    func relayPublicKeyCheck() throws {
        let relay = EventSigner(keyPair: KeyPair())
        let impostor = EventSigner(keyPair: KeyPair())

        for (kind, parse) in stateParsers {
            let forged = try stateEvent(kind: kind, tags: [.identifier("abcdef")], signer: impostor)
            #expect(
                throws: Groups.ValidationError.unexpectedAuthor(
                    expected: relay.publicKey, actual: impostor.publicKey)
            ) {
                try parse(forged, relay.publicKey)
            }

            let genuine = try stateEvent(kind: kind, tags: [.identifier("abcdef")], signer: relay)
            #expect(throws: Never.self) { try parse(genuine, relay.publicKey) }
        }
    }

    // MARK: State Filters

    @Test("groupState filters on the d tag with the five state kinds by default")
    func groupStateFilterDefaults() {
        let filter = Filter.groupState(groupID: "abcdef")

        #expect(filter.kinds == [.groupMetadata, .groupAdmins, .groupMembers, .groupRoles, .groupPinList])
        #expect(filter[tag: "d"] == ["abcdef"])
    }

    @Test("groupState honors a custom kind list")
    func groupStateFilterCustomKinds() {
        let filter = Filter.groupState(groupID: "abcdef", kinds: [.groupMetadata])

        #expect(filter.kinds == [.groupMetadata])
        #expect(filter[tag: "d"] == ["abcdef"])
    }
}

@Suite("NIP-29 Group Membership")
struct NIP29GroupMembershipTests {
    let member = PublicKey.fixture("member")

    /// The 64-character event id whose first 8 characters encode `index` in hex.
    private func paddedID(_ index: Int) -> EventID {
        EventID(String(format: "%08x", index) + String(repeating: "0", count: 56))!
    }

    /// Builds a moderation-event literal with a controlled id and timestamp; membership
    /// derivation never verifies signatures.
    private func moderation(
        id: EventID,
        kind: Event.Kind,
        createdAt: Timestamp,
        tags: [Event.Tag]
    ) -> Event {
        Event(
            id: id, publicKey: PublicKey.fixture("admin"), createdAt: createdAt, kind: kind, tags: tags, content: "",
            signature: nil)
    }

    private func putUser(id: EventID, createdAt: Timestamp, roles: [String]) -> Event {
        moderation(
            id: id, kind: .groupPutUser, createdAt: createdAt,
            tags: [.group("abcdef"), .publicKey(member, roles: roles)])
    }

    private func removeUser(id: EventID, createdAt: Timestamp) -> Event {
        moderation(
            id: id, kind: .groupRemoveUser, createdAt: createdAt,
            tags: [.group("abcdef"), .publicKey(member)])
    }

    @Test("membership is nil when no moderation event targets the public key")
    func noRelevantEvents() {
        #expect(Groups.membership(of: member, in: [Event]()) == nil)
    }

    @Test("the latest put-user event wins and carries its roles")
    func latestPutUserWins() {
        let events = [
            putUser(id: paddedID(1), createdAt: Timestamp(rawValue: 1_700_000_000), roles: ["member"]),
            putUser(id: paddedID(2), createdAt: Timestamp(rawValue: 1_700_000_100), roles: ["admin", "moderator"]),
        ]

        #expect(Groups.membership(of: member, in: events) == .member(roles: ["admin", "moderator"]))
        #expect(
            Groups.membership(of: member, in: events.reversed())
                == .member(roles: ["admin", "moderator"]))
    }

    @Test("a later remove-user event removes the member")
    func laterRemoveWins() {
        let events = [
            putUser(id: paddedID(1), createdAt: Timestamp(rawValue: 1_700_000_000), roles: ["member"]),
            removeUser(id: paddedID(2), createdAt: Timestamp(rawValue: 1_700_000_100)),
        ]

        #expect(Groups.membership(of: member, in: events) == .removed)
    }

    @Test("a put-user event after a removal re-adds the member")
    func reAddAfterRemoval() {
        let events = [
            putUser(id: paddedID(1), createdAt: Timestamp(rawValue: 1_700_000_000), roles: ["member"]),
            removeUser(id: paddedID(2), createdAt: Timestamp(rawValue: 1_700_000_100)),
            putUser(id: paddedID(3), createdAt: Timestamp(rawValue: 1_700_000_200), roles: []),
        ]

        #expect(Groups.membership(of: member, in: events) == .member(roles: []))
    }

    @Test("a created-at tie is broken by the lowest event id")
    func tieBrokenByLowestID() {
        let createdAt = Timestamp(rawValue: 1_700_000_000)
        let removal = removeUser(id: EventID(String(repeating: "a", count: 64))!, createdAt: createdAt)
        let put = putUser(id: EventID(String(repeating: "b", count: 64))!, createdAt: createdAt, roles: ["member"])

        #expect(Groups.membership(of: member, in: [removal, put]) == .removed)
        #expect(Groups.membership(of: member, in: [put, removal]) == .removed)
    }

    @Test("moderation events targeting other public keys are ignored")
    func otherPublicKeysIgnored() {
        let other = PublicKey.fixture("other")
        let events = [
            putUser(id: paddedID(1), createdAt: Timestamp(rawValue: 1_700_000_000), roles: ["member"]),
            moderation(
                id: paddedID(2), kind: .groupRemoveUser, createdAt: Timestamp(rawValue: 1_700_000_100),
                tags: [.group("abcdef"), .publicKey(other)]),
        ]

        #expect(Groups.membership(of: member, in: events) == .member(roles: ["member"]))
        #expect(Groups.membership(of: other, in: events) == .removed)
    }

    @Test("events of other kinds never affect membership")
    func otherKindsIgnored() {
        let events = [
            putUser(id: paddedID(1), createdAt: Timestamp(rawValue: 1_700_000_000), roles: ["member"]),
            moderation(
                id: paddedID(2), kind: .chatMessage, createdAt: Timestamp(rawValue: 1_700_000_100),
                tags: [.group("abcdef"), .publicKey(member)]),
            moderation(
                id: paddedID(3), kind: .groupDeleteEvent, createdAt: Timestamp(rawValue: 1_700_000_200),
                tags: [.group("abcdef"), .publicKey(member)]),
        ]

        #expect(Groups.membership(of: member, in: events) == .member(roles: ["member"]))
    }

    @Test("a put-user event with several p tags applies the matching one")
    func multiplePublicKeyTags() {
        let other = PublicKey.fixture("other")
        let event = moderation(
            id: paddedID(1), kind: .groupPutUser, createdAt: Timestamp(rawValue: 1_700_000_000),
            tags: [
                .group("abcdef"), Event.Tag(name: .publicKey, values: [other.hex, "ceo"]),
                Event.Tag(name: .publicKey, values: [member.hex, "moderator"]),
            ])

        #expect(Groups.membership(of: member, in: [event]) == .member(roles: ["moderator"]))
        #expect(Groups.membership(of: other, in: [event]) == .member(roles: ["ceo"]))
    }
}
