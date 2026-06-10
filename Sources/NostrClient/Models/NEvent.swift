import Foundation

/// A NIP-19 `nevent` entity: an event id with optional relay hints, author, and kind.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NEvent: Sendable, Hashable {
    /// The referenced event id (32-byte lowercase hex).
    public let eventId: String

    /// Relay hints where the event may be found.
    public let relays: [String]

    /// The author's public key (32-byte lowercase hex), if known.
    public let author: String?

    /// The event kind, if known.
    public let kind: Int?

    /// Creates an event reference. Throws if `eventId`/`author` are not 32-byte hex
    /// or `kind` does not fit in a 32-bit unsigned integer.
    public init(eventId: String, relays: [String] = [], author: String? = nil, kind: Int? = nil) throws {
        self.eventId = try TLV.normalizedHex32(eventId)
        self.relays = try TLV.validatedRelays(relays)
        self.author = try author.map(TLV.normalizedHex32)
        self.kind = try kind.map(TLV.validatedKind)
    }

    /// Decodes an `nevent` bech32 string.
    public init(bech32String: String) throws {
        let (hrp, data) = try Bech32.decode(bech32String)
        guard hrp == "nevent" else {
            throw NostrError.unknownPrefix(hrp)
        }
        try self.init(tlvData: data)
    }

    /// Builds an `nevent` reference from a known event, capturing its id, author, and kind.
    public init(event: Event, relays: [String] = []) throws {
        try self.init(eventId: event.id, relays: relays, author: event.pubkey, kind: event.kind)
    }

    init(tlvData: Data) throws {
        var eventId: String?
        var relays: [String] = []
        var author: String?
        var kind: Int?
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                guard record.value.count == 32 else {
                    throw NostrError.invalidNIP19Entity
                }
                eventId = record.value.hexEncodedString()
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
        guard let eventId else {
            throw NostrError.invalidNIP19Entity
        }
        self.eventId = eventId
        self.relays = relays
        self.author = author
        self.kind = kind
    }

    /// The canonical `nevent` bech32 string.
    public var encoded: String {
        var records = [TLV.Record(type: TLV.Kind.special.rawValue, value: Data(hexString: eventId) ?? Data())]
        records += relays.map { TLV.Record(type: TLV.Kind.relay.rawValue, value: Data($0.utf8)) }
        if let author {
            records.append(TLV.Record(type: TLV.Kind.author.rawValue, value: Data(hexString: author) ?? Data()))
        }
        if let kind {
            records.append(TLV.Record(type: TLV.Kind.kind.rawValue, value: TLV.encodeKind(kind)))
        }
        let data = (try? TLV.encode(records)) ?? Data()
        return Bech32.encode(hrp: "nevent", data: data)
    }
}
