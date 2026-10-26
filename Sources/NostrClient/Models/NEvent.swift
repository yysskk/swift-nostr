import Foundation
import NostrCore

/// A NIP-19 `nevent` entity: an event id with optional relay hints, author, and kind.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NEvent: Sendable, Hashable {
    /// The referenced event id.
    public let eventID: EventID

    /// Relay hints where the event may be found.
    public let relays: [String]

    /// The author's public key, if known.
    public let author: PublicKey?

    /// The event kind, if known.
    public let kind: Int?

    /// Creates an event reference.
    /// - Throws: ``NostrError/invalidTLV`` if a relay hint is longer than 255 bytes, or
    ///   ``NostrError/invalidNIP19Entity`` if `kind` does not fit in a 32-bit unsigned integer.
    public init(eventID: EventID, relays: [String] = [], author: PublicKey? = nil, kind: Int? = nil) throws {
        self.eventID = eventID
        self.relays = try TLV.validatedRelays(relays)
        self.author = author
        self.kind = try kind.map(TLV.validatedKind)
    }

    /// Decodes an `nevent` bech32 string.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if the payload has no event id, or an event id or
    ///   author that is not 32 bytes, besides the bech32 and TLV errors.
    public init(bech32String: String) throws {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "nevent"))
    }

    /// Builds an `nevent` reference from a known event, capturing its id, author, and kind.
    public init(event: Event, relays: [String] = []) throws {
        try self.init(eventID: event.id, relays: relays, author: event.pubkey, kind: event.kind.rawValue)
    }

    init(tlvData: Data) throws {
        var eventID: EventID?
        var relays: [String] = []
        var author: PublicKey?
        var kind: Int?
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                eventID = try TLV.eventID(record)
            case TLV.Kind.relay.rawValue:
                relays.append(String(decoding: record.value, as: UTF8.self))
            case TLV.Kind.author.rawValue:
                author = try TLV.publicKey(record)
            case TLV.Kind.kind.rawValue:
                kind = try TLV.decodeKind(record.value)
            default:
                continue
            }
        }
        guard let eventID else {
            throw NostrError.invalidNIP19Entity
        }
        self.eventID = eventID
        self.relays = relays
        self.author = author
        self.kind = kind
    }

    /// The canonical `nevent` bech32 string.
    public var encoded: String {
        get throws {
            var records = [TLV.specialRecord(eventID)] + TLV.relayRecords(relays)
            if let author {
                records.append(TLV.authorRecord(author))
            }
            if let kind {
                records.append(TLV.kindRecord(kind))
            }
            return try TLV.bech32(records, prefix: "nevent")
        }
    }
}
