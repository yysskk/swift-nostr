/// The reason category of a NIP-56 report (kind 1984).
/// https://github.com/nostr-protocol/nips/blob/master/56.md
public enum ReportType: String, Sendable, Hashable, CaseIterable, Codable {
    case nudity
    case malware
    case profanity
    case illegal
    case spam
    case impersonation
    case other
}
