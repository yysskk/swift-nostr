import Foundation
import NostrCore

/// Where a NIP-29 group lives: the (relay, group id) pair, optionally with the relay's
/// pubkey (the author of its kind-39000 metadata) and an invite code — everything an
/// `naddr` share link carries.
///
/// Groups are shared as the `naddr` of their kind-39000 metadata event, sometimes with an
/// invite code appended as a `?invite=<code>` suffix:
///
/// ```swift
/// let group = try GroupReference(naddrString: "naddr1...?invite=A7fjq2")
/// try await client.groups.join(group)  // the invite code is applied automatically
/// ```
///
/// https://github.com/nostr-protocol/nips/blob/master/29.md
public struct GroupReference: Sendable, Hashable {
    /// The URL of the relay hosting the group.
    public let relayURL: String

    /// The group's id on its relay.
    public let id: String

    /// The relay's public key (hex) — the expected author of the group's kind-39xxx state.
    /// Nil when unknown.
    public let relayPubkey: String?

    /// An invite code from a "?invite=<code>" share-link suffix. Nil when absent.
    public let inviteCode: String?

    /// Characters an invite code may carry verbatim in a share link; everything else is
    /// percent-encoded by ``shareableString()`` so ``init(naddrString:)`` round-trips it.
    private static let inviteCodeAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    public init(relayURL: String, id: String, relayPubkey: String? = nil, inviteCode: String? = nil) {
        self.relayURL = relayURL
        self.id = id
        self.relayPubkey = relayPubkey
        self.inviteCode = inviteCode
    }

    /// Builds a reference from a kind-39000 `naddr`: the author is the relay's pubkey, the
    /// "d" identifier is the group id, and the first non-empty relay hint is the group's relay.
    ///
    /// - Parameters:
    ///   - naddr: The coordinate of the group's kind-39000 metadata event.
    ///   - inviteCode: An invite code shared alongside the coordinate, if any.
    /// - Throws: ``NostrError/invalidNIP19Entity`` unless the coordinate's kind is 39000 and
    ///   it carries at least one non-empty relay hint — a group without a relay is unusable.
    public init(naddr: NAddr, inviteCode: String? = nil) throws {
        guard naddr.kind == Event.Kind.groupMetadata.rawValue,
            let relayURL = naddr.relays.first(where: { !$0.isEmpty })
        else {
            throw NostrError.invalidNIP19Entity
        }
        self.init(relayURL: relayURL, id: naddr.identifier, relayPubkey: naddr.author, inviteCode: inviteCode)
    }

    /// Parses a share-link string: an "naddr1..." coordinate with an optional
    /// "?invite=<code>" suffix.
    ///
    /// The string is split at the first "?" (which cannot occur inside bech32); the query is
    /// read URL-style, so a percent-encoded invite code is decoded, with the raw value kept
    /// when the query does not parse as URL components.
    ///
    /// - Throws: ``NostrError/invalidBech32`` and friends when the coordinate does not
    ///   decode, or ``NostrError/invalidNIP19Entity`` when it is not a usable kind-39000
    ///   group coordinate (see ``init(naddr:inviteCode:)``).
    public init(naddrString: String) throws {
        let parts = naddrString.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let inviteCode = parts.count == 2 ? Self.inviteCode(fromQuery: String(parts[1])) : nil
        try self.init(naddr: NAddr(bech32String: String(parts[0])), inviteCode: inviteCode)
    }

    /// The "invite" value of a share-link query string, percent-decoded when the query
    /// parses as URL components and taken raw otherwise. Nil when absent or empty.
    private static func inviteCode(fromQuery query: String) -> String? {
        let code: String?
        if let components = URLComponents(string: "?\(query)"), let items = components.queryItems {
            code = items.first(where: { $0.name == "invite" })?.value
        } else {
            code = query.split(separator: "&")
                .first(where: { $0.hasPrefix("invite=") })
                .map { String($0.dropFirst("invite=".count)) }
        }
        guard let code, !code.isEmpty else { return nil }
        return code
    }

    /// The coordinate of the group's kind-39000 metadata event: identifier = ``id``,
    /// author = ``relayPubkey``, with ``relayURL`` as the single relay hint.
    ///
    /// - Throws: ``NostrError/invalidNIP19Entity`` when ``relayPubkey`` is unknown — an
    ///   `naddr` cannot be built without its author.
    public func naddr() throws -> NAddr {
        guard let relayPubkey else {
            throw NostrError.invalidNIP19Entity
        }
        return try NAddr(
            identifier: id,
            author: relayPubkey,
            kind: Event.Kind.groupMetadata.rawValue,
            relays: [relayURL]
        )
    }

    /// The shareable string: the ``naddr()`` coordinate, plus "?invite=<code>" when
    /// ``inviteCode`` is set (the code percent-encoded so ``init(naddrString:)`` round-trips it).
    ///
    /// - Throws: ``NostrError/invalidNIP19Entity`` when ``relayPubkey`` is unknown.
    public func shareableString() throws -> String {
        let encoded = try naddr().encoded
        guard let inviteCode else { return encoded }
        let code = inviteCode.addingPercentEncoding(withAllowedCharacters: Self.inviteCodeAllowed) ?? inviteCode
        return "\(encoded)?invite=\(code)"
    }
}
