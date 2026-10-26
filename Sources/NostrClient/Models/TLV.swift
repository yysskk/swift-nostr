import Foundation
import NostrCore

/// Type-Length-Value records and field validation shared by the NIP-19
/// `nprofile`, `nevent`, and `naddr` entities.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
enum TLV {
    enum Kind: UInt8 {
        /// The entity's primary value: the pubkey (`nprofile`), event id (`nevent`),
        /// or `d`-tag identifier (`naddr`).
        case special = 0
        /// A relay-hint URL. May appear multiple times.
        case relay = 1
        /// The author's pubkey (32 bytes).
        case author = 2
        /// The event kind, big-endian.
        case kind = 3
    }

    struct Record {
        let type: UInt8
        let value: Data
    }

    /// Serializes records as `type | length | value`, concatenated.
    /// Throws `.invalidTLV` if any value exceeds 255 bytes.
    static func encode(_ records: [Record]) throws -> Data {
        var data = Data()
        for record in records {
            guard record.value.count <= 255 else {
                throw NostrError.invalidTLV
            }
            data.append(record.type)
            data.append(UInt8(record.value.count))
            data.append(record.value)
        }
        return data
    }

    /// Parses a raw byte buffer into records. Unknown types are preserved so callers
    /// can skip them. Throws `.invalidTLV` if a record is truncated.
    static func decode(_ data: Data) throws -> [Record] {
        let bytes = [UInt8](data)
        var records: [Record] = []
        var index = 0
        while index < bytes.count {
            guard index + 1 < bytes.count else {
                throw NostrError.invalidTLV
            }
            let type = bytes[index]
            let length = Int(bytes[index + 1])
            let valueStart = index + 2
            let valueEnd = valueStart + length
            guard valueEnd <= bytes.count else {
                throw NostrError.invalidTLV
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
    static func decodeKind(_ data: Data) throws -> Int {
        guard (1...4).contains(data.count) else {
            throw NostrError.invalidTLV
        }
        var value: UInt32 = 0
        for byte in data {
            value = (value << 8) | UInt32(byte)
        }
        return Int(value)
    }

    /// The public key a 32-byte ``Kind/special`` or ``Kind/author`` record carries.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if the record does not hold exactly 32 bytes.
    static func publicKey(_ record: Record) throws -> PublicKey {
        guard let key = try? PublicKey(data: record.value) else {
            throw NostrError.invalidNIP19Entity
        }
        return key
    }

    /// The event id a 32-byte ``Kind/special`` record carries.
    /// - Throws: ``NostrError/invalidNIP19Entity`` if the record does not hold exactly 32 bytes.
    static func eventID(_ record: Record) throws -> EventID {
        guard let id = try? EventID(data: record.value) else {
            throw NostrError.invalidNIP19Entity
        }
        return id
    }

    /// Ensures each relay URL's canonical form fits within a single TLV record (255 bytes).
    static func validatedRelays(_ relays: [RelayURL]) throws -> [RelayURL] {
        for relay in relays where relay.description.utf8.count > 255 {
            throw NostrError.invalidTLV
        }
        return relays
    }

    /// Validates that an event kind fits in a 32-bit unsigned integer.
    static func validatedKind(_ kind: Int) throws -> Int {
        // `UInt32(exactly:)` rejects negative values and values above `UInt32.max`
        // without relying on an `Int` literal that would overflow on 32-bit
        // platforms such as watchOS.
        guard UInt32(exactly: kind) != nil else {
            throw NostrError.invalidNIP19Entity
        }
        return kind
    }

    // MARK: - Entity Round-Trip Helpers

    /// Decodes a bech32 string into its TLV payload, verifying the human-readable prefix.
    /// Shared by the `nprofile`/`nevent`/`naddr` `init(bech32String:)` initializers.
    static func payload(fromBech32 string: String, prefix: String) throws -> Data {
        let (hrp, data) = try Bech32.decode(string)
        guard hrp == prefix else {
            throw NostrError.unknownPrefix(hrp)
        }
        return data
    }

    /// Encodes records into a bech32 string with the given prefix.
    ///
    /// Throws ``NostrError/invalidTLV`` if a record value exceeds 255 bytes, or
    /// ``NostrError/invalidBech32`` if `prefix` is not ASCII. Neither happens for the
    /// entity `encoded` accessors: their initializers validate every field and the
    /// prefixes are constant ASCII literals.
    static func bech32(_ records: [Record], prefix: String) throws -> String {
        let data = try encode(records)
        return try Bech32.encode(hrp: prefix, data: data)
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
