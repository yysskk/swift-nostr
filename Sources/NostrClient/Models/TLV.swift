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

    /// Validates a 32-byte hex string and returns its canonical lowercase form.
    static func normalizedHex32(_ hex: String) throws -> String {
        guard let data = Data(hexString: hex), data.count == 32 else {
            throw NostrError.invalidHex
        }
        return data.hexEncodedString()
    }

    /// Ensures each relay URL fits within a single TLV record (255 bytes).
    static func validatedRelays(_ relays: [String]) throws -> [String] {
        for relay in relays where relay.utf8.count > 255 {
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
    /// Encoding errors (a value over 255 bytes) yield an empty payload, matching the
    /// lenient `encoded` accessors on the entity types — which only fail to round-trip
    /// values that their throwing initializers already reject.
    static func bech32(_ records: [Record], prefix: String) -> String {
        Bech32.encode(hrp: prefix, data: (try? encode(records)) ?? Data())
    }

    /// A ``Kind/special`` record carrying raw bytes (used for the `naddr` identifier).
    static func specialRecord(_ value: Data) -> Record {
        Record(type: Kind.special.rawValue, value: value)
    }

    /// A ``Kind/special`` record carrying a value decoded from 32-byte hex
    /// (the `nprofile` pubkey or `nevent` event id).
    static func specialRecord(hex: String) -> Record {
        specialRecord(Data(hexString: hex) ?? Data())
    }

    /// ``Kind/relay`` records, one per relay-hint URL.
    static func relayRecords(_ urls: [String]) -> [Record] {
        urls.map { Record(type: Kind.relay.rawValue, value: Data($0.utf8)) }
    }

    /// A ``Kind/author`` record carrying a pubkey decoded from 32-byte hex.
    static func authorRecord(hex: String) -> Record {
        Record(type: Kind.author.rawValue, value: Data(hexString: hex) ?? Data())
    }

    /// A ``Kind/kind`` record carrying a big-endian event kind.
    static func kindRecord(_ kind: Int) -> Record {
        Record(type: Kind.kind.rawValue, value: encodeKind(kind))
    }
}
