import Foundation

// MARK: - Validation
extension Groups {
    /// Why a NIP-29 group event failed parsing or validation.
    public enum ValidationError: Error, Equatable, Sendable, LocalizedError {
        /// The event is not of the kind the model parses.
        case invalidEventKind(expected: Event.Kind, actual: Event.Kind)
        /// The event carries no group id: no non-empty "d" tag (relay-generated state) or
        /// "h" tag (moderation events).
        case missingGroupID(Event.Kind)
        /// The event author is not the expected relay pubkey.
        case unexpectedAuthor(expected: String, actual: String)
        /// The event lacks a tag the kind requires (e.g. a kind-9000 without "p").
        case missingTag(name: String, kind: Event.Kind)
        /// The kind is not one of the moderation kinds this library models (defined by the
        /// spec: 9000-9002, 9005, 9007-9010).
        case unsupportedModerationKind(Event.Kind)

        public var errorDescription: String? {
            switch self {
            case .invalidEventKind(let expected, let actual):
                return "Expected a kind-\(expected) group event, got kind \(actual)"
            case .missingGroupID(let kind):
                return "The kind-\(kind) group event carries no d or h tag with a group id"
            case .unexpectedAuthor(let expected, let actual):
                return "The group event author \(actual) is not the expected relay pubkey \(expected)"
            case .missingTag(let name, let kind):
                return "The kind-\(kind) group event lacks a required \(name) tag"
            case .unsupportedModerationKind(let kind):
                return "Kind \(kind) is not a NIP-29 moderation kind"
            }
        }
    }

    /// Runs the checks shared by every relay-generated state parser — the event kind, and
    /// the author when `relayPubkey` is given — and returns the group id from the "d" tag.
    fileprivate static func validatedGroupID(
        of event: Event,
        expecting kind: Event.Kind,
        relayPubkey: String?
    ) throws -> String {
        guard event.kind == kind else {
            throw ValidationError.invalidEventKind(expected: kind, actual: event.kind)
        }
        if let relayPubkey, event.pubkey != relayPubkey {
            throw ValidationError.unexpectedAuthor(expected: relayPubkey, actual: event.pubkey)
        }
        guard let groupID = event.firstTagValue(named: "d"), !groupID.isEmpty else {
            throw ValidationError.missingGroupID(kind)
        }
        return groupID
    }
}

// MARK: - Group Metadata (kind 39000)
extension Groups {
    /// A group's kind-39000 metadata, generated and signed by the group's relay.
    ///
    /// Flag tags are presence-based: "private", "restricted", "hidden", "closed", and
    /// "livekit" set their flag by appearing at all, and the parser also recognizes the
    /// explicit "public" and "open" complements as false. Tags the model does not
    /// interpret are preserved in ``additionalTags`` for lossless re-emission; duplicate
    /// occurrences of recognized scalar tags (e.g. a second "name") are dropped — the first
    /// wins — so ``toTags`` re-emission is not byte-lossless for such duplicates.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct Metadata: Sendable, Hashable {
        /// The group's id on its relay (the event's "d" tag).
        public var groupID: String

        /// The group's display name, if any.
        public var name: String?

        /// The group's picture URL, if any.
        public var picture: String?

        /// The group's banner image URL, if any.
        public var banner: String?

        /// The group's description, if any.
        public var about: String?

        /// Whether only members can read the group's events ("private"); false means
        /// publicly readable ("public").
        public var isPrivate: Bool

        /// Whether only members can write to the group ("restricted").
        public var isRestricted: Bool

        /// Whether the group's metadata is hidden from non-members ("hidden").
        public var isHidden: Bool

        /// Whether join requests are ignored ("closed"); false means anyone can ask to
        /// join ("open").
        public var isClosed: Bool

        /// Whether the group has AV rooms ("livekit"); LiveKit itself is out of scope for
        /// this library.
        public var isLiveKitEnabled: Bool

        /// The event kinds the relay accepts into the group ("supported_kinds"). Nil when
        /// the tag is absent — every kind allowed — while [] means explicitly none.
        public var supportedKinds: [Event.Kind]?

        /// The id of the group this group is a subgroup of ("parent"), if any; the spec
        /// allows at most one.
        public var parentGroupID: String?

        /// The ids of this group's subgroups ("child" tags), in order.
        public var childGroupIDs: [String]

        /// Every tag the model does not interpret (excluding "d"), in order, preserved
        /// for lossless re-emission.
        public var additionalTags: [Tag]

        public init(
            groupID: String,
            name: String? = nil,
            picture: String? = nil,
            banner: String? = nil,
            about: String? = nil,
            isPrivate: Bool = false,
            isRestricted: Bool = false,
            isHidden: Bool = false,
            isClosed: Bool = false,
            isLiveKitEnabled: Bool = false,
            supportedKinds: [Event.Kind]? = nil,
            parentGroupID: String? = nil,
            childGroupIDs: [String] = [],
            additionalTags: [Tag] = []
        ) {
            self.groupID = groupID
            self.name = name
            self.picture = picture
            self.banner = banner
            self.about = about
            self.isPrivate = isPrivate
            self.isRestricted = isRestricted
            self.isHidden = isHidden
            self.isClosed = isClosed
            self.isLiveKitEnabled = isLiveKitEnabled
            self.supportedKinds = supportedKinds
            self.parentGroupID = parentGroupID
            self.childGroupIDs = childGroupIDs
            self.additionalTags = additionalTags
        }

        /// Parses a relay-generated kind-39000 metadata event.
        ///
        /// The first occurrence of each recognized tag wins; non-integer
        /// "supported_kinds" values are dropped leniently. Never verifies the event
        /// signature — callers check ``Event/verify()`` themselves.
        ///
        /// - Parameters:
        ///   - event: The kind-39000 event to parse.
        ///   - relayPubkey: The group relay's public key (hex); when given, an event by
        ///     any other author is rejected. Nil skips the author check.
        /// - Throws: ``ValidationError`` naming the first failed check.
        public init(event: Event, relayPubkey: String? = nil) throws {
            let groupID = try Groups.validatedGroupID(
                of: event, expecting: .groupMetadata, relayPubkey: relayPubkey)
            self.init(groupID: groupID, fieldTags: event.structuredTags)
        }

        /// Interprets metadata field tags — the tag layout of a kind-39000 event without its
        /// "d" tag, which is also exactly what a kind-9002 edit-metadata event carries. "d"
        /// tags are skipped; unrecognized tags are preserved in ``additionalTags``.
        public init(groupID: String, fieldTags: some Sequence<Tag>) {
            self.groupID = groupID

            var name: String?
            var picture: String?
            var banner: String?
            var about: String?
            var isPrivate: Bool?
            var isRestricted = false
            var isHidden = false
            var isClosed: Bool?
            var isLiveKitEnabled = false
            var supportedKinds: [Event.Kind]?
            var parentGroupID: String?
            var childGroupIDs: [String] = []
            var additionalTags: [Tag] = []

            for tag in fieldTags {
                switch tag.name {
                case "d":
                    break
                case "name":
                    if name == nil { name = tag.primaryValue }
                case "picture":
                    if picture == nil { picture = tag.primaryValue }
                case "banner":
                    if banner == nil { banner = tag.primaryValue }
                case "about":
                    if about == nil { about = tag.primaryValue }
                case "private":
                    if isPrivate == nil { isPrivate = true }
                case "public":
                    if isPrivate == nil { isPrivate = false }
                case "restricted":
                    isRestricted = true
                case "hidden":
                    isHidden = true
                case "closed":
                    if isClosed == nil { isClosed = true }
                case "open":
                    if isClosed == nil { isClosed = false }
                case "livekit":
                    isLiveKitEnabled = true
                case "supported_kinds":
                    if supportedKinds == nil {
                        supportedKinds = tag.values.compactMap { Int($0) }.map(Event.Kind.init(rawValue:))
                    }
                case "parent":
                    if parentGroupID == nil { parentGroupID = tag.primaryValue }
                case "child":
                    if let child = tag.primaryValue { childGroupIDs.append(child) }
                default:
                    additionalTags.append(tag)
                }
            }

            self.name = name
            self.picture = picture
            self.banner = banner
            self.about = about
            self.isPrivate = isPrivate ?? false
            self.isRestricted = isRestricted
            self.isHidden = isHidden
            self.isClosed = isClosed ?? false
            self.isLiveKitEnabled = isLiveKitEnabled
            self.supportedKinds = supportedKinds
            self.parentGroupID = parentGroupID
            self.childGroupIDs = childGroupIDs
            self.additionalTags = additionalTags
        }

        /// The complete wire tags of the kind-39000 event: `["d", groupID]` first, then
        /// ``fieldTags``.
        public var toTags: [Tag] {
            [.identifier(groupID)] + fieldTags
        }

        /// Every tag except "d" — what a kind-9002 edit-metadata event carries. Emits
        /// name/picture/banner/about when non-nil; "private" or "public" and "closed" or
        /// "open" (complementary pairs, matching the reference implementation);
        /// "restricted"/"hidden"/"livekit" only when true; "supported_kinds" when
        /// non-nil; "parent"/"child"; then ``additionalTags``.
        public var fieldTags: [Tag] {
            var tags: [Tag] = []
            if let name { tags.append(Tag(name: "name", values: [name])) }
            if let picture { tags.append(Tag(name: "picture", values: [picture])) }
            if let banner { tags.append(Tag(name: "banner", values: [banner])) }
            if let about { tags.append(Tag(name: "about", values: [about])) }
            tags.append(Tag(name: isPrivate ? "private" : "public"))
            tags.append(Tag(name: isClosed ? "closed" : "open"))
            if isRestricted { tags.append(Tag(name: "restricted")) }
            if isHidden { tags.append(Tag(name: "hidden")) }
            if isLiveKitEnabled { tags.append(Tag(name: "livekit")) }
            if let supportedKinds {
                tags.append(Tag(name: "supported_kinds", values: supportedKinds.map { String($0.rawValue) }))
            }
            if let parentGroupID { tags.append(Tag(name: "parent", values: [parentGroupID])) }
            tags.append(contentsOf: childGroupIDs.map { Tag(name: "child", values: [$0]) })
            tags.append(contentsOf: additionalTags)
            return tags
        }
    }
}

// MARK: - Admin List (kind 39001)
extension Groups {
    /// One admin of a kind-39001 list: `["p", pubkey, role...]`.
    public struct Admin: Sendable, Hashable {
        /// The admin's public key (hex).
        public var pubkey: String

        /// The admin's role names, in order ([] for an admin listed without roles).
        public var roles: [String]

        public init(pubkey: String, roles: [String] = []) {
            self.pubkey = pubkey
            self.roles = roles
        }
    }

    /// A group's kind-39001 admin list, generated and signed by the group's relay: one
    /// "p" tag per admin, carrying the pubkey and trailing role names.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct AdminList: Sendable, Hashable {
        /// The group's id on its relay (the event's "d" tag).
        public var groupID: String

        /// The group's admins, one per "p" tag, in order.
        public var admins: [Admin]

        public init(groupID: String, admins: [Admin] = []) {
            self.groupID = groupID
            self.admins = admins
        }

        /// Parses a relay-generated kind-39001 admin list event.
        ///
        /// Never verifies the event signature — callers check ``Event/verify()``
        /// themselves.
        ///
        /// - Parameters:
        ///   - event: The kind-39001 event to parse.
        ///   - relayPubkey: The group relay's public key (hex); when given, an event by
        ///     any other author is rejected. Nil skips the author check.
        /// - Throws: ``ValidationError`` naming the first failed check.
        public init(event: Event, relayPubkey: String? = nil) throws {
            groupID = try Groups.validatedGroupID(
                of: event, expecting: .groupAdmins, relayPubkey: relayPubkey)
            admins = event.tags(named: "p").compactMap { tag in
                guard let pubkey = tag.primaryValue else { return nil }
                return Admin(pubkey: pubkey, roles: Array(tag.values.dropFirst()))
            }
        }

        /// The complete wire tags of the kind-39001 event: `["d", groupID]` first, then
        /// one `["p", pubkey, role...]` tag per admin.
        public var toTags: [Tag] {
            [.identifier(groupID)] + admins.map { .pubkey($0.pubkey, roles: $0.roles) }
        }
    }
}

// MARK: - Member List (kind 39002)
extension Groups {
    /// A group's kind-39002 member list, generated and signed by the group's relay: one
    /// "p" tag per member.
    ///
    /// Relays may omit this event entirely, restrict it to members, or publish a partial
    /// list — never treat it as exhaustive.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct MemberList: Sendable, Hashable {
        /// The group's id on its relay (the event's "d" tag).
        public var groupID: String

        /// The listed members' public keys (hex), one per "p" tag, in order.
        public var members: [String]

        public init(groupID: String, members: [String] = []) {
            self.groupID = groupID
            self.members = members
        }

        /// Parses a relay-generated kind-39002 member list event.
        ///
        /// Never verifies the event signature — callers check ``Event/verify()``
        /// themselves.
        ///
        /// - Parameters:
        ///   - event: The kind-39002 event to parse.
        ///   - relayPubkey: The group relay's public key (hex); when given, an event by
        ///     any other author is rejected. Nil skips the author check.
        /// - Throws: ``ValidationError`` naming the first failed check.
        public init(event: Event, relayPubkey: String? = nil) throws {
            groupID = try Groups.validatedGroupID(
                of: event, expecting: .groupMembers, relayPubkey: relayPubkey)
            members = event.tags(named: "p").compactMap(\.primaryValue)
        }

        /// The complete wire tags of the kind-39002 event: `["d", groupID]` first, then
        /// one `["p", pubkey]` tag per member.
        public var toTags: [Tag] {
            [.identifier(groupID)] + members.map { .pubkey($0) }
        }
    }
}

// MARK: - Role List (kind 39003)
extension Groups {
    /// One relay-defined role of a kind-39003 event: `["role", name, description?]`.
    public struct Role: Sendable, Hashable {
        /// The role's name, as referenced by "p" tags and moderation events.
        public var name: String

        /// A human-readable description of what the role can do, if any.
        public var description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    /// A group's kind-39003 role list — the roles this relay understands — generated and
    /// signed by the group's relay.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct RoleList: Sendable, Hashable {
        /// The group's id on its relay (the event's "d" tag).
        public var groupID: String

        /// The relay's roles, one per "role" tag, in order.
        public var roles: [Role]

        public init(groupID: String, roles: [Role] = []) {
            self.groupID = groupID
            self.roles = roles
        }

        /// Parses a relay-generated kind-39003 role list event.
        ///
        /// Never verifies the event signature — callers check ``Event/verify()``
        /// themselves.
        ///
        /// - Parameters:
        ///   - event: The kind-39003 event to parse.
        ///   - relayPubkey: The group relay's public key (hex); when given, an event by
        ///     any other author is rejected. Nil skips the author check.
        /// - Throws: ``ValidationError`` naming the first failed check.
        public init(event: Event, relayPubkey: String? = nil) throws {
            groupID = try Groups.validatedGroupID(
                of: event, expecting: .groupRoles, relayPubkey: relayPubkey)
            roles = event.tags(named: "role").compactMap { tag in
                guard let name = tag.primaryValue else { return nil }
                return Role(name: name, description: tag.values.count > 1 ? tag.values[1] : nil)
            }
        }

        /// The complete wire tags of the kind-39003 event: `["d", groupID]` first, then
        /// one `["role", name, description?]` tag per role.
        public var toTags: [Tag] {
            [.identifier(groupID)] + roles.map { .role($0.name, description: $0.description) }
        }
    }
}

// MARK: - Pin List (kind 39005)
extension Groups {
    /// A pinned item of a kind-39005 pin list: an "e" event id or an "a" address.
    public enum PinnedItem: Sendable, Hashable {
        /// A pinned event, referenced by id in an "e" tag.
        case event(id: String)
        /// A pinned addressable event, referenced by its "kind:pubkey:identifier"
        /// coordinate in an "a" tag.
        case address(String)
    }

    /// A group's kind-39005 pin list, generated and signed by the group's relay.
    ///
    /// Order is meaningful (pin order) and preserved exactly; "e" and "a" tags may
    /// interleave. Other tags are ignored.
    /// https://github.com/nostr-protocol/nips/blob/master/29.md
    public struct PinList: Sendable, Hashable {
        /// The group's id on its relay (the event's "d" tag).
        public var groupID: String

        /// The pinned items, in pin order.
        public var items: [PinnedItem]

        public init(groupID: String, items: [PinnedItem] = []) {
            self.groupID = groupID
            self.items = items
        }

        /// Parses a relay-generated kind-39005 pin list event.
        ///
        /// Never verifies the event signature — callers check ``Event/verify()``
        /// themselves.
        ///
        /// - Parameters:
        ///   - event: The kind-39005 event to parse.
        ///   - relayPubkey: The group relay's public key (hex); when given, an event by
        ///     any other author is rejected. Nil skips the author check.
        /// - Throws: ``ValidationError`` naming the first failed check.
        public init(event: Event, relayPubkey: String? = nil) throws {
            groupID = try Groups.validatedGroupID(
                of: event, expecting: .groupPinList, relayPubkey: relayPubkey)
            items = event.structuredTags.compactMap { tag in
                switch tag.name {
                case "e":
                    return tag.primaryValue.map { PinnedItem.event(id: $0) }
                case "a":
                    return tag.primaryValue.map { PinnedItem.address($0) }
                default:
                    return nil
                }
            }
        }

        /// The complete wire tags of the kind-39005 event: `["d", groupID]` first, then
        /// one `["e", id]` or `["a", address]` tag per item, in pin order.
        public var toTags: [Tag] {
            [.identifier(groupID)]
                + items.map { item in
                    switch item {
                    case .event(let id):
                        return .event(id)
                    case .address(let address):
                        return Tag(name: "a", values: [address])
                    }
                }
        }
    }
}

// MARK: - Membership
extension Groups {
    /// A user's membership standing in a group, derived from moderation history.
    public enum Membership: Sendable, Hashable {
        /// The user was last added or updated by a kind-9000 put-user event carrying
        /// these role names ([] for a plain member).
        case member(roles: [String])
        /// The user was last removed by a kind-9001 remove-user event.
        case removed
    }

    /// Derives a pubkey's membership standing from kind-9000/9001 moderation events.
    ///
    /// The latest event targeting `pubkey` in a "p" tag wins, with ties on `createdAt`
    /// broken by the lowest event id — the NIP-01 replaceable-event convention. Events of
    /// other kinds, and events not targeting `pubkey`, are ignored. Never verifies event
    /// signatures — callers check ``Event/verify()`` themselves.
    ///
    /// - Parameters:
    ///   - pubkey: The user's public key (hex).
    ///   - events: The group's moderation events, in any order.
    /// - Returns: ``Membership/member(roles:)`` with the roles from the winning
    ///   kind-9000 event's matching "p" tag, ``Membership/removed`` for a winning
    ///   kind-9001, or nil when no event targets `pubkey` — the spec says to assume
    ///   non-membership then.
    public static func membership(of pubkey: String, in events: some Sequence<Event>) -> Membership? {
        var latest: (event: Event, roles: [String])?
        for event in events where event.kind == .groupPutUser || event.kind == .groupRemoveUser {
            guard let target = event.tags(named: "p").first(where: { $0.primaryValue == pubkey }) else {
                continue
            }
            if let current = latest?.event {
                let supersedes =
                    event.createdAt > current.createdAt
                    || (event.createdAt == current.createdAt && event.id < current.id)
                guard supersedes else { continue }
            }
            latest = (event, Array(target.values.dropFirst()))
        }
        guard let latest else { return nil }
        return latest.event.kind == .groupPutUser ? .member(roles: latest.roles) : .removed
    }
}
