import Foundation
import NostrCore

/// Type-Length-Value records and field validation shared by the NIP-19
/// `nprofile`, `nevent`, and `naddr` entities.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
enum TLV {
    enum Kind: UInt8 {
        /// The entity's primary value: the public key (`nprofile`), event id (`nevent`),
        /// or `d`-tag identifier (`naddr`).
        case special = 0
        /// A relay-hint URL. May appear multiple times.
        case relay = 1
        /// The author's public key (32 bytes).
        case author = 2
        /// The event kind, big-endian.
        case kind = 3
    }

    struct Record {
        let type: UInt8
        let value: Data
    }

    /// Serializes records as `type | length | value`, concatenated.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if any value exceeds 255 bytes.
    static func encode(_ records: [Record]) throws(NIP19Entity.Error) -> Data {
        var data = Data()
        for record in records {
            guard record.value.count <= 255 else {
                throw .fieldTooLong(record.value.count)
            }
            data.append(record.type)
            data.append(UInt8(record.value.count))
            data.append(record.value)
        }
        return data
    }

    /// Parses a raw byte buffer into records. Unknown types are preserved so callers
    /// can skip them.
    /// - Throws: ``NIP19Entity/Error/malformedTLV`` if a record is truncated.
    static func decode(_ data: Data) throws(NIP19Entity.Error) -> [Record] {
        let bytes = [UInt8](data)
        var records: [Record] = []
        var index = 0
        while index < bytes.count {
            guard index + 1 < bytes.count else {
                throw .malformedTLV
            }
            let type = bytes[index]
            let length = Int(bytes[index + 1])
            let valueStart = index + 2
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count else {
                throw .malformedTLV
            }
            records.append(Record(type: type, value: Data(bytes[valueStart..<valueEnd])))
            index = valueEnd
        }
        return records
    }

    /// Encodes an event kind as a 4-byte big-endian unsigned integer.
    static func encodeKind(_ kind: Int) -> Data {
        let value = UInt32(truncatingIfNeeded: kind)
        return Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    /// Decodes a big-endian event kind, leniently accepting 1–4 bytes.
    /// - Throws: ``NIP19Entity/Error/invalidLength(_:)`` for any other length.
    static func decodeKind(_ data: Data) throws(NIP19Entity.Error) -> Int {
        guard (1...4).contains(data.count) else {
            throw .invalidLength(data.count)
        }
        var value: UInt32 = 0
        for byte in data {
            value = (value << 8) | UInt32(byte)
        }
        return Int(value)
    }

    /// The public key an `npub` payload or a ``Kind/special`` or ``Kind/author`` record carries.
    /// - Throws: ``NIP19Entity/Error/invalidLength(_:)`` if `data` is not exactly 32 bytes.
    static func publicKey(_ data: Data) throws(NIP19Entity.Error) -> PublicKey {
        do throws(PublicKey.Error) {
            return try PublicKey(data: data)
        } catch {
            throw .invalidLength(data.count)
        }
    }

    /// The event id a `note` payload or a ``Kind/special`` record carries.
    /// - Throws: ``NIP19Entity/Error/invalidLength(_:)`` if `data` is not exactly 32 bytes.
    static func eventID(_ data: Data) throws(NIP19Entity.Error) -> EventID {
        do throws(EventID.Error) {
            return try EventID(data: data)
        } catch {
            throw .invalidLength(data.count)
        }
    }

    /// Ensures each relay URL's canonical form fits within a single TLV record (255 bytes).
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` for a longer one.
    static func validatedRelays(_ relays: [RelayURL]) throws(NIP19Entity.Error) -> [RelayURL] {
        for relay in relays where relay.description.utf8.count > 255 {
            throw .fieldTooLong(relay.description.utf8.count)
        }
        return relays
    }

    /// Validates that an event kind fits in a 32-bit unsigned integer.
    /// - Throws: ``NIP19Entity/Error/kindOutOfRange(_:)`` otherwise.
    static func validatedKind(_ kind: Int) throws(NIP19Entity.Error) -> Int {
        // `UInt32(exactly:)` rejects negative values and values above `UInt32.max`
        // without relying on an `Int` literal that would overflow on 32-bit
        // platforms such as watchOS.
        guard UInt32(exactly: kind) != nil else {
            throw .kindOutOfRange(kind)
        }
        return kind
    }

    // MARK: - Entity Round-Trip Helpers

    /// Decodes a bech32 string, reporting a bech32 failure as a NIP-19 one.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if `string` is not valid bech32.
    static func decodeBech32(_ string: String) throws(NIP19Entity.Error) -> (hrp: String, data: Data) {
        do throws(Bech32.Error) {
            return try Bech32.decode(string)
        } catch {
            throw .invalidBech32(error)
        }
    }

    /// Encodes `data` as bech32, reporting a bech32 failure as a NIP-19 one.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if `hrp` is not lowercase printable
    ///   ASCII, which never happens for the constant NIP-19 prefixes.
    static func encodeBech32(hrp: String, data: Data) throws(NIP19Entity.Error) -> String {
        do throws(Bech32.Error) {
            return try Bech32.encode(hrp: hrp, data: data)
        } catch {
            throw .invalidBech32(error)
        }
    }

    /// Decodes a bech32 string into its TLV payload, verifying the human-readable prefix.
    /// Shared by the `nprofile`/`nevent`/`naddr` `init(bech32String:)` initializers.
    /// - Throws: ``NIP19Entity/Error/invalidBech32(_:)`` if `string` is not valid bech32, or
    ///   ``NIP19Entity/Error/unexpectedPrefix(_:)`` if its prefix is not `prefix`.
    static func payload(fromBech32 string: String, prefix: String) throws(NIP19Entity.Error) -> Data {
        let (hrp, data) = try decodeBech32(string)
        guard hrp == prefix else {
            throw .unexpectedPrefix(hrp)
        }
        return data
    }

    /// Encodes records into a bech32 string with the given prefix.
    /// - Throws: ``NIP19Entity/Error/fieldTooLong(_:)`` if a record value exceeds 255 bytes — for
    ///   the entity `encoded` accessors only an `naddr` identifier can, as their initializers
    ///   validate the relay hints.
    static func bech32(_ records: [Record], prefix: String) throws(NIP19Entity.Error) -> String {
        let data = try encode(records)
        return try encodeBech32(hrp: prefix, data: data)
    }

    /// A ``Kind/special`` record carrying raw bytes (used for the `naddr` identifier).
    static func specialRecord(_ value: Data) -> Record {
        Record(type: Kind.special.rawValue, value: value)
    }

    /// A ``Kind/special`` record carrying the `nprofile` public key.
    static func specialRecord(_ publicKey: PublicKey) -> Record {
        specialRecord(publicKey.data)
    }

    /// A ``Kind/special`` record carrying the `nevent` event id.
    static func specialRecord(_ eventID: EventID) -> Record {
        specialRecord(eventID.data)
    }

    /// ``Kind/relay`` records, one per relay-hint URL, in canonical form.
    static func relayRecords(_ urls: [RelayURL]) -> [Record] {
        urls.map { Record(type: Kind.relay.rawValue, value: Data($0.description.utf8)) }
    }

    /// The relay hint a ``Kind/relay`` record carries, or nil when it is not a valid relay URL.
    /// Relay hints come from whoever encoded the entity, so a malformed one is skipped rather
    /// than failing the whole entity.
    static func relay(_ record: Record) -> RelayURL? {
        RelayURL(String(decoding: record.value, as: UTF8.self))
    }

    /// A ``Kind/author`` record carrying the author's public key.
    static func authorRecord(_ author: PublicKey) -> Record {
        Record(type: Kind.author.rawValue, value: author.data)
    }

    /// A ``Kind/kind`` record carrying a big-endian event kind.
    static func kindRecord(_ kind: Int) -> Record {
        Record(type: Kind.kind.rawValue, value: encodeKind(kind))
    }
}
