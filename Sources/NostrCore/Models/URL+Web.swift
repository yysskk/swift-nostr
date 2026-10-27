import Foundation

extension URL {
    /// Whether the URL is `http` or `https` and names a host.
    ///
    /// A URL that a third party supplies and the package later fetches — a file message's location,
    /// an LNURL-pay callback — must pass this, so a peer cannot point a download at a `file:`,
    /// `data:`, or custom-scheme URL.
    package var isWebURL: Bool {
        guard let components = URLComponents(url: self, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else {
            return false
        }
        return true
    }
}
