import Foundation
import NostrCore

/// Where a NIP-29 group lives: the (relay, group id) pair, optionally with the relay's
/// public key (the author of its kind-39000 metadata) and an invite code — everything an
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
    public let relayURL: RelayURL

    /// The group's id on its relay.
    public let id: String

    /// The relay's public key — the expected author of the group's kind-39xxx state.
    /// Nil when unknown.
    public let relayPublicKey: PublicKey?

    /// An invite code from a "?invite=<code>" share-link suffix. Nil when absent.
    public let inviteCode: String?

    /// Characters an invite code may carry verbatim in a share link; everything else is
    /// percent-encoded by ``shareableString()`` so ``init(naddrString:)`` round-trips it.
    private static let inviteCodeAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    /// Creates a reference to the group `id` on the relay at `relayURL`.
    /// - Parameters:
    ///   - relayURL: The URL of the relay hosting the group.
    ///   - id: The group's id on its relay.
    ///   - relayPublicKey: The relay's public key, if known; group state is validated against it.
    ///   - inviteCode: An invite code to send with a join request, if any.
    public init(relayURL: RelayURL, id: String, relayPublicKey: PublicKey? = nil, inviteCode: String? = nil) {
        self.relayURL = relayURL
        self.id = id
        self.relayPublicKey = relayPublicKey
        self.inviteCode = inviteCode
    }

    /// Builds a reference from a kind-39000 `naddr`: the author is the relay's public key, the
    /// "d" identifier is the group id, and the first relay hint is the group's relay.
    ///
    /// - Parameters:
    ///   - naddr: The coordinate of the group's kind-39000 metadata event.
    ///   - inviteCode: An invite code shared alongside the coordinate, if any.
    /// - Throws: ``GroupReference/Error/unexpectedKind(_:)`` unless the coordinate's kind is
    ///   39000, or ``GroupReference/Error/missingRelay`` unless it carries at least one valid relay
    ///   hint — a group without a relay is unusable.
    public init(naddr: NAddr, inviteCode: String? = nil) throws(GroupReference.Error) {
        guard naddr.kind == .groupMetadata else {
            throw .unexpectedKind(naddr.kind)
        }
        guard let relayURL = naddr.relays.first else {
            throw .missingRelay
        }
        self.init(relayURL: relayURL, id: naddr.identifier, relayPublicKey: naddr.author, inviteCode: inviteCode)
    }

    /// Parses a share-link string: an "naddr1..." coordinate with an optional
    /// "?invite=<code>" suffix.
    ///
    /// The string is split at the first "?" (which cannot occur inside bech32); the query is
    /// read URL-style, so a percent-encoded invite code is decoded, with the raw value kept
    /// when the query does not parse as URL components.
    ///
    /// - Throws: ``GroupReference/Error/invalidCoordinate(_:)`` when the coordinate does not
    ///   decode as an `naddr`, or the errors of ``init(naddr:inviteCode:)`` when it is not a usable
    ///   kind-39000 group coordinate.
    public init(naddrString: String) throws(GroupReference.Error) {
        let parts = naddrString.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let inviteCode = parts.count == 2 ? Self.inviteCode(fromQuery: String(parts[1])) : nil
        let naddr: NAddr
        do throws(NIP19Entity.Error) {
            naddr = try NAddr(bech32String: String(parts[0]))
        } catch {
            throw .invalidCoordinate(error)
        }
        try self.init(naddr: naddr, inviteCode: inviteCode)
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
    /// author = ``relayPublicKey``, with ``relayURL`` as the single relay hint.
    ///
    /// - Throws: ``GroupReference/Error/unknownRelayPublicKey`` when ``relayPublicKey`` is
    ///   unknown — an `naddr` cannot be built without its author — or
    ///   ``GroupReference/Error/invalidCoordinate(_:)`` when ``relayURL`` is too long for one.
    public func naddr() throws(GroupReference.Error) -> NAddr {
        guard let relayPublicKey else {
            throw .unknownRelayPublicKey
        }
        do throws(NIP19Entity.Error) {
            return try NAddr(
                identifier: id,
                author: relayPublicKey,
                kind: .groupMetadata,
                relays: [relayURL]
            )
        } catch {
            throw .invalidCoordinate(error)
        }
    }

    /// The shareable string: the ``naddr()`` coordinate, plus "?invite=<code>" when
    /// ``inviteCode`` is set (the code percent-encoded so ``init(naddrString:)`` round-trips it).
    ///
    /// - Throws: ``GroupReference/Error/unknownRelayPublicKey`` when ``relayPublicKey`` is unknown,
    ///   or ``GroupReference/Error/invalidCoordinate(_:)`` when the coordinate does not encode.
    public func shareableString() throws(GroupReference.Error) -> String {
        let coordinate = try naddr()
        let encoded: String
        do throws(NIP19Entity.Error) {
            encoded = try coordinate.encoded
        } catch {
            throw .invalidCoordinate(error)
        }
        guard let inviteCode else { return encoded }
        let code = inviteCode.addingPercentEncoding(withAllowedCharacters: Self.inviteCodeAllowed) ?? inviteCode
        return "\(encoded)?invite=\(code)"
    }

    /// An error building a group reference from, or encoding one as, an `naddr`.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The coordinate does not decode or encode as an `naddr`.
        case invalidCoordinate(NIP19Entity.Error)
        /// The coordinate is not of a kind-39000 group metadata event (payload: its kind).
        case unexpectedKind(Event.Kind)
        /// The coordinate carries no valid relay hint, so the group's relay is unknown.
        case missingRelay
        /// ``GroupReference/relayPublicKey`` is unknown, so there is no author to address the
        /// group's metadata by.
        case unknownRelayPublicKey

        public var errorDescription: String? {
            switch self {
            case .invalidCoordinate(let error):
                return "Invalid group coordinate: \(error.errorDescription ?? "invalid naddr")"
            case .unexpectedKind(let kind):
                return "A group coordinate must be of kind 39000, got \(kind.rawValue)"
            case .missingRelay:
                return "A group coordinate must carry a relay hint"
            case .unknownRelayPublicKey:
                return "A group's naddr needs the relay's public key"
            }
        }
    }
}
