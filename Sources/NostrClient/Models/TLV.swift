import Foundation

/// Type-Length-Value records and field validation shared by the NIP-19
/// `nprofile`, `nevent`, and `naddr` entities.
///
/// https://github.com/nostr-protocol/nips/blob/master/19.md
enum TLV {
    enum Kind: UInt8 {
        case special = 0
        case relay = 1
        case author = 2
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
        guard (0...0xFFFF_FFFF).contains(kind) else {
            throw NostrError.invalidNIP19Entity
        }
        return kind
    }
}
