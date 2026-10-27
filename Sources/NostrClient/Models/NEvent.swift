import Foundation
import NostrCore

/// A NIP-19 `nevent` entity: an event id with optional relay hints, author, and kind.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NEvent: Sendable, Hashable {
    /// The referenced event id.
    public let eventID: EventID

    /// Relay hints where the event may be found. Decoding skips a hint that is not a valid
    /// relay URL; encoding writes each hint in canonical form.
    public let relays: [RelayURL]

    /// The author's public key, if known.
    public let author: PublicKey?

    /// The event kind, if known.
    public let kind: Event.Kind?

    /// Creates an event reference.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes, or ``NIP19Entity/Error/kindOutOfRange(_:)`` if `kind` does not fit in a
    ///   32-bit unsigned integer.
    public init(
        eventID: EventID, relays: [RelayURL] = [], author: PublicKey? = nil, kind: Event.Kind? = nil
    ) throws(NIP19Entity.Error) {
        self.eventID = eventID
        self.relays = try TLV.validatedRelays(relays)
        self.author = author
        self.kind = try kind.map(TLV.validatedKind)
    }

    /// Decodes an `nevent` bech32 string.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if the string is not valid bech32,
    ///   ``NIP19Entity/Error/unexpectedPrefix(_:)`` if its prefix is not `nevent`,
    ///   ``NIP19Entity/Error/malformedTLV`` if a record is truncated,
    ///   ``NIP19Entity/Error/missingEventID`` if it has no event id, or
    ///   ``NIP19Entity/Error/invalidLength(_:)`` if the event id or author is not 32 bytes or the
    ///   kind is not 1–4 bytes.
    public init(bech32String: String) throws(NIP19Entity.Error) {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "nevent"))
    }

    /// Builds an `nevent` reference from a known event, capturing its id, author, and kind.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes, or ``NIP19Entity/Error/kindOutOfRange(_:)`` if the event's kind does not
    ///   fit in a 32-bit unsigned integer.
    public init(event: Event, relays: [RelayURL] = []) throws(NIP19Entity.Error) {
        try self.init(eventID: event.id, relays: relays, author: event.publicKey, kind: event.kind)
    }

    init(tlvData: Data) throws(NIP19Entity.Error) {
        var eventID: EventID?
        var relays: [RelayURL] = []
        var author: PublicKey?
        var kind: Event.Kind?
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                eventID = try TLV.eventID(record.value)
            case TLV.Kind.relay.rawValue:
                if let relay = TLV.relay(record) {
                    relays.append(relay)
                }
            case TLV.Kind.author.rawValue:
                author = try TLV.publicKey(record.value)
            case TLV.Kind.kind.rawValue:
                kind = try TLV.decodeKind(record.value)
            default:
                continue
            }
        }
        guard let eventID else {
            throw .missingEventID
        }
        self.eventID = eventID
        self.relays = relays
        self.author = author
        self.kind = kind
    }

    /// The canonical `nevent` bech32 string.
    public var encoded: String {
        get throws(NIP19Entity.Error) {
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
