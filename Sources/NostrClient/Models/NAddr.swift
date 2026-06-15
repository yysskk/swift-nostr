import Foundation
import NostrCore

/// A NIP-19 `naddr` entity: a coordinate to an addressable (parameterized replaceable) event.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NAddr: Sendable, Hashable {
    /// The `d` tag value identifying the event. May be empty.
    public let identifier: String

    /// The author's public key (32-byte lowercase hex).
    public let author: String

    /// The event kind.
    public let kind: Int

    /// Relay hints where the event may be found.
    public let relays: [String]

    /// Creates an addressable-event coordinate. Throws if `author` is not 32-byte hex
    /// or `kind` does not fit in a 32-bit unsigned integer.
    public init(identifier: String, author: String, kind: Int, relays: [String] = []) throws {
        self.identifier = identifier
        self.author = try TLV.normalizedHex32(author)
        self.kind = try TLV.validatedKind(kind)
        self.relays = try TLV.validatedRelays(relays)
    }

    /// Decodes an `naddr` bech32 string.
    public init(bech32String: String) throws {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "naddr"))
    }

    /// Builds an `naddr` coordinate from an addressable event, extracting its `d` tag.
    public init(event: Event, relays: [String] = []) throws {
        let identifier = event.tags.first { $0.first == "d" }.flatMap { $0.count > 1 ? $0[1] : "" } ?? ""
        try self.init(identifier: identifier, author: event.pubkey, kind: event.kind.rawValue, relays: relays)
    }

    init(tlvData: Data) throws {
        var identifier: String?
        var author: String?
        var kind: Int?
        var relays: [String] = []
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                identifier = String(decoding: record.value, as: UTF8.self)
            case TLV.Kind.relay.rawValue:
                relays.append(String(decoding: record.value, as: UTF8.self))
            case TLV.Kind.author.rawValue:
                guard record.value.count == 32 else {
                    throw NostrError.invalidNIP19Entity
                }
                author = record.value.hexEncodedString()
            case TLV.Kind.kind.rawValue:
                kind = try TLV.decodeKind(record.value)
            default:
                continue
            }
        }
        guard let identifier, let author, let kind else {
            throw NostrError.invalidNIP19Entity
        }
        self.identifier = identifier
        self.author = author
        self.kind = kind
        self.relays = relays
    }

    /// The canonical `naddr` bech32 string.
    public var encoded: String {
        let records =
            [TLV.specialRecord(Data(identifier.utf8))]
            + TLV.relayRecords(relays)
            + [TLV.authorRecord(hex: author), TLV.kindRecord(kind)]
        return TLV.bech32(records, prefix: "naddr")
    }
}
