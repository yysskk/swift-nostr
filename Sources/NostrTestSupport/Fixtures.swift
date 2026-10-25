import Foundation
import NostrCore

// Well-formed placeholder values for tests that build events by hand and never hash or sign them.
// Each is derived deterministically from a label, so distinct labels give distinct values and the
// same label always gives the same one.

extension PublicKey {
    /// A well-formed public key derived from `label`. Not a point anyone holds the private key for.
    public static func fixture(_ label: String) -> PublicKey {
        // Fixture bytes always have the right length, so this cannot throw.
        try! PublicKey(data: fixtureBytes(label, count: 32))
    }
}

extension EventID {
    /// A well-formed event id derived from `label`. Not the hash of any event.
    public static func fixture(_ label: String) -> EventID {
        try! EventID(data: fixtureBytes(label, count: 32))
    }
}

extension Signature {
    /// A well-formed signature derived from `label`. It verifies for no event.
    public static func fixture(_ label: String = "") -> Signature {
        try! Signature(data: fixtureBytes(label, count: 64))
    }
}

/// `count` bytes from FNV-1a over `label`, re-seeded for each 8-byte block.
private func fixtureBytes(_ label: String, count: Int) -> Data {
    var data = Data(capacity: count)
    var block: UInt64 = 0
    while data.count < count {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 ^ block
        for byte in label.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        withUnsafeBytes(of: hash.bigEndian) { data.append(contentsOf: $0) }
        block += 1
    }
    return data
}
