import Foundation
import NostrCore

/// One `["group", groupID, relayURL, name?]` entry of a NIP-51 kind-10009 simple group
/// list: a NIP-29 group the list's author is in, identified by its (relay, group id) pair
/// with an optional display name.
///
/// https://github.com/nostr-protocol/nips/blob/master/51.md
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct GroupListEntry: Sendable, Hashable {
    /// The group's id on its relay.
    public var groupID: String

    /// The URL of the relay hosting the group.
    public var relayURL: String

    /// An optional human-readable group name. An empty string is normalized to nil on
    /// every construction and mutation path, so an entry always round-trips through its
    /// wire ``tag`` unchanged.
    public var name: String? {
        didSet {
            if name?.isEmpty == true { name = nil }
        }
    }

    public init(groupID: String, relayURL: String, name: String? = nil) {
        self.groupID = groupID
        self.relayURL = relayURL
        self.name = name?.isEmpty == true ? nil : name
    }

    /// Builds an entry from a group reference.
    ///
    /// The name is a display convenience; the reference's `relayPubkey` and `inviteCode`
    /// are not part of the list format and are dropped.
    public init(_ reference: GroupReference, name: String? = nil) {
        self.init(groupID: reference.id, relayURL: reference.relayURL, name: name)
    }

    /// Parses a `["group", id, relay, name?]` tag.
    ///
    /// Returns nil unless the tag is named "group" with a non-empty id, a non-empty relay
    /// URL, and no values beyond the optional name — an out-of-shape "group" tag is left
    /// to ``SimpleGroupList``'s additional-tag buckets so its content survives a round
    /// trip. A present-but-empty name is treated as nil.
    public init?(tag: Tag) {
        guard tag.name == "group", (2...3).contains(tag.values.count) else { return nil }
        let groupID = tag.values[0]
        let relayURL = tag.values[1]
        guard !groupID.isEmpty, !relayURL.isEmpty else { return nil }
        let name = tag.values.count == 3 && !tag.values[2].isEmpty ? tag.values[2] : nil
        self.init(groupID: groupID, relayURL: relayURL, name: name)
    }

    /// The wire tag: `["group", groupID, relayURL, name?]`
    /// (``Event/Tag/simpleGroup(id:relayURL:name:)``).
    public var tag: Tag {
        .simpleGroup(id: groupID, relayURL: relayURL, name: name)
    }

    /// The entry as a ``GroupReference``.
    ///
    /// The list format carries no relay pubkey or invite code, so both are nil.
    public var reference: GroupReference {
        GroupReference(relayURL: relayURL, id: groupID)
    }
}

/// The NIP-51 "Simple groups" list (kind 10009): the NIP-29 groups a user is in, plus the
/// relays in use (`"r"` tags) — what other clients read to detect group migrations and
/// forks.
///
/// A typed view over ``NostrList``: convert with ``init(list:)`` and ``list``, and private
/// entries ride the existing NIP-44 machinery (``EventSigner/signList(_:)`` /
/// ``EventSigner/openList(_:)``). Publish and fetch through
/// ``NostrClient/publishSimpleGroupList(_:strategy:)`` and
/// ``NostrClient/fetchSimpleGroupList(for:timeout:)``.
///
/// https://github.com/nostr-protocol/nips/blob/master/51.md
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct SimpleGroupList: Sendable, Hashable {
    /// The publicly visible group entries.
    public var publicEntries: [GroupListEntry]

    /// Group entries NIP-44-self-encrypted into the event content, readable only by the
    /// author.
    public var privateEntries: [GroupListEntry]

    /// The `"r"` relay URLs of the public tags, in order — the relays the author uses for
    /// groups, one tag per relay. (Private `"r"` tags, if any, stay in
    /// ``additionalPrivateTags``.)
    public var relayURLs: [String]

    /// Public tags that are neither well-formed `["group", id, relay, name?]` tags nor
    /// single-value `["r", url]` tags, preserved in order.
    public var additionalPublicTags: [Tag]

    /// Private tags that are not well-formed `["group", id, relay, name?]` tags, preserved
    /// in order.
    public var additionalPrivateTags: [Tag]

    public init(
        publicEntries: [GroupListEntry] = [],
        privateEntries: [GroupListEntry] = [],
        relayURLs: [String] = [],
        additionalPublicTags: [Tag] = [],
        additionalPrivateTags: [Tag] = []
    ) {
        self.publicEntries = publicEntries
        self.privateEntries = privateEntries
        self.relayURLs = relayURLs
        self.additionalPublicTags = additionalPublicTags
        self.additionalPrivateTags = additionalPrivateTags
    }

    /// Builds the typed view of a kind-10009 list.
    ///
    /// Well-formed `["group", ...]` tags become ``publicEntries`` and ``privateEntries``,
    /// and public single-value `["r", url]` tags become ``relayURLs``; every other tag
    /// lands in ``additionalPublicTags`` or ``additionalPrivateTags`` — including
    /// out-of-shape "group" and "r" tags, so nothing is dropped.
    ///
    /// - Throws: ``NostrError/invalidData`` when `list.kind` is not
    ///   ``Event/Kind/simpleGroupList``.
    public init(list: NostrList) throws {
        guard list.kind == .simpleGroupList else {
            throw NostrError.invalidData
        }
        var publicEntries: [GroupListEntry] = []
        var relayURLs: [String] = []
        var additionalPublicTags: [Tag] = []
        for tag in list.publicItems {
            if let entry = GroupListEntry(tag: tag) {
                publicEntries.append(entry)
            } else if tag.name == "r", tag.values.count == 1, !tag.values[0].isEmpty {
                relayURLs.append(tag.values[0])
            } else {
                additionalPublicTags.append(tag)
            }
        }
        var privateEntries: [GroupListEntry] = []
        var additionalPrivateTags: [Tag] = []
        for tag in list.privateItems {
            if let entry = GroupListEntry(tag: tag) {
                privateEntries.append(entry)
            } else {
                additionalPrivateTags.append(tag)
            }
        }
        self.init(
            publicEntries: publicEntries,
            privateEntries: privateEntries,
            relayURLs: relayURLs,
            additionalPublicTags: additionalPublicTags,
            additionalPrivateTags: additionalPrivateTags
        )
    }

    /// The underlying kind-10009 ``NostrList``.
    ///
    /// Public items are the ``publicEntries``' tags first, then an `["r", url]` tag per
    /// ``relayURLs`` element, then ``additionalPublicTags``; private items are the
    /// ``privateEntries``' tags followed by ``additionalPrivateTags``. Converting a list
    /// through ``init(list:)`` and back normalizes that grouping — and drops the
    /// present-but-empty name element of a "group" tag — but preserves every tag's
    /// content.
    public var list: NostrList {
        var publicItems = publicEntries.map(\.tag)
        publicItems.append(contentsOf: relayURLs.map { Tag.reference($0) })
        publicItems.append(contentsOf: additionalPublicTags)
        return NostrList(
            kind: .simpleGroupList,
            publicItems: publicItems,
            privateItems: privateEntries.map(\.tag) + additionalPrivateTags
        )
    }
}
