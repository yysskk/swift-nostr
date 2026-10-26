import Foundation
import NostrCore

@testable import NostrClient

/// Encodes NIP-19 TLV entities with relay hints given as raw strings, the way a third party may
/// have written them — including hints the typed initializers cannot produce.
enum RawTLV {
    static func bech32(
        prefix: String,
        special: Data,
        relays: [String],
        author: PublicKey? = nil,
        kind: Int? = nil
    ) throws -> String {
        var records = [TLV.specialRecord(special)]
        records += relays.map { TLV.Record(type: TLV.Kind.relay.rawValue, value: Data($0.utf8)) }
        if let author {
            records.append(TLV.authorRecord(author))
        }
        if let kind {
            records.append(TLV.kindRecord(kind))
        }
        return try TLV.bech32(records, prefix: prefix)
    }
}
