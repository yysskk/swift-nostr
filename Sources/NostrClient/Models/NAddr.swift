import Foundation
import NostrCore

/// A NIP-19 `naddr` entity: a coordinate to an addressable (parameterized replaceable) event.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
public struct NAddr: Sendable, Hashable {
    /// The `d` tag value identifying the event. May be empty.
    public let identifier: String

    /// The author's public key.
    public let author: PublicKey

    /// The event kind.
    public let kind: Int

    /// Relay hints where the event may be found. Decoding skips a hint that is not a valid
    /// relay URL; encoding writes each hint in canonical form.
    public let relays: [RelayURL]

    /// Creates an addressable-event coordinate.
    /// - Throws: ``NIP19Entity/Error/kindOutOfRange(_:)`` if `kind` does not fit in a 32-bit
    ///   unsigned integer, or ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical
    ///   form is longer than 255 bytes.
    public init(
        identifier: String, author: PublicKey, kind: Int, relays: [RelayURL] = []
    ) throws(NIP19Entity.Error) {
        self.identifier = identifier
        self.author = author
        self.kind = try TLV.validatedKind(kind)
        self.relays = try TLV.validatedRelays(relays)
    }

    /// Decodes an `naddr` bech32 string.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if the string is not valid bech32,
    ///   ``NIP19Entity/Error/unexpectedPrefix(_:)`` if its prefix is not `naddr`,
    ///   ``NIP19Entity/Error/malformedTLV`` if a record is truncated,
    ///   ``NIP19Entity/Error/missingIdentifier``, ``NIP19Entity/Error/missingAuthor``, or
    ///   ``NIP19Entity/Error/missingKind`` if it lacks that record, or
    ///   ``NIP19Entity/Error/invalidLength(_:)`` if the author is not 32 bytes or the kind is not
    ///   1–4 bytes.
    public init(bech32String: String) throws(NIP19Entity.Error) {
        try self.init(tlvData: TLV.payload(fromBech32: bech32String, prefix: "naddr"))
    }

    /// Builds an `naddr` coordinate from an addressable event, extracting its `d` tag.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a relay hint's canonical form is longer
    ///   than 255 bytes, or ``NIP19Entity/Error/kindOutOfRange(_:)`` if the event's kind does not
    ///   fit in a 32-bit unsigned integer.
    public init(event: Event, relays: [RelayURL] = []) throws(NIP19Entity.Error) {
        let identifier = event.firstTagValue(named: .identifier) ?? ""
        try self.init(identifier: identifier, author: event.publicKey, kind: event.kind.rawValue, relays: relays)
    }

    init(tlvData: Data) throws(NIP19Entity.Error) {
        var identifier: String?
        var author: PublicKey?
        var kind: Int?
        var relays: [RelayURL] = []
        for record in try TLV.decode(tlvData) {
            switch record.type {
            case TLV.Kind.special.rawValue:
                identifier = String(decoding: record.value, as: UTF8.self)
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
        guard let identifier else { throw .missingIdentifier }
        guard let author else { throw .missingAuthor }
        guard let kind else { throw .missingKind }
        self.identifier = identifier
        self.author = author
        self.kind = kind
        self.relays = relays
    }

    /// The canonical `naddr` bech32 string.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if ``identifier`` is longer than 255 bytes.
    public var encoded: String {
        get throws(NIP19Entity.Error) {
            let records =
                [TLV.specialRecord(Data(identifier.utf8))]
                + TLV.relayRecords(relays)
                + [TLV.authorRecord(author), TLV.kindRecord(kind)]
            return try TLV.bech32(records, prefix: "naddr")
        }
    }
}
