import Foundation

/// LNURL-pay helpers for NIP-57 Lightning zaps.
///
/// https://github.com/nostr-protocol/nips/blob/master/57.md
public enum LNURL {
    /// Resolves a lud16 lightning address ("name@domain") to its LNURL-pay service URL,
    /// `https://<domain>/.well-known/lnurlp/<name>`.
    /// - Returns: The service URL, or nil if `address` is not a valid `name@domain` pair.
    public static func payServiceURL(forLightningAddress address: String) -> URL? {
        // LUD-16 splits on the last "@" (like an email): the name precedes it, the domain follows.
        guard let atIndex = address.lastIndex(of: "@") else { return nil }
        let name = String(address[..<atIndex])
        let domain = String(address[address.index(after: atIndex)...])

        // The domain is the URL authority, so it must not smuggle a path or query; the name is a
        // single path segment, so it is percent-encoded (escaping "/" prevents path traversal).
        let segmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#;"))
        guard !name.isEmpty, !domain.isEmpty,
            !domain.contains(where: { "/?#".contains($0) }),
            let encodedName = name.addingPercentEncoding(withAllowedCharacters: segmentAllowed)
        else {
            return nil
        }
        return URL(string: "https://\(domain)/.well-known/lnurlp/\(encodedName)")
    }

    /// Decodes a bech32 `lnurl` string (a lud06 value) into its URL.
    /// - Throws: ``NostrError/invalidBech32`` if the string is not a valid `lnurl` bech32 URL.
    public static func decode(_ lnurl: String) throws -> URL {
        let (hrp, data) = try Bech32.decode(lnurl)
        guard hrp == "lnurl",
            let string = String(data: data, encoding: .utf8),
            let url = URL(string: string)
        else {
            throw NostrError.invalidBech32
        }
        return url
    }

    /// Encodes a URL as a bech32 `lnurl` string, as used in a zap request's `lnurl` tag.
    public static func encode(_ url: URL) -> String {
        Bech32.encode(hrp: "lnurl", data: Data(url.absoluteString.utf8))
    }
}

/// An LNURL-pay service response — the JSON returned by an LNURL-pay endpoint, with the fields
/// NIP-57 zaps rely on. Decode the endpoint's response into this, then build an invoice request
/// with ``invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``.
public struct LNURLPayResponse: Decodable, Sendable, Hashable {
    /// The URL to send the zap request / invoice request to.
    public let callback: String

    /// Minimum payable amount in millisatoshis.
    public let minSendable: Int64

    /// Maximum payable amount in millisatoshis.
    public let maxSendable: Int64

    /// Whether the endpoint supports Nostr zaps.
    public let allowsNostr: Bool?

    /// The pubkey the endpoint uses to sign kind-9735 zap receipts.
    public let nostrPubkey: String?

    /// The maximum comment length the endpoint accepts, if it accepts comments.
    public let commentAllowed: Int?

    public init(
        callback: String,
        minSendable: Int64,
        maxSendable: Int64,
        allowsNostr: Bool? = nil,
        nostrPubkey: String? = nil,
        commentAllowed: Int? = nil
    ) {
        self.callback = callback
        self.minSendable = minSendable
        self.maxSendable = maxSendable
        self.allowsNostr = allowsNostr
        self.nostrPubkey = nostrPubkey
        self.commentAllowed = commentAllowed
    }

    /// Whether this endpoint can receive zaps: it advertises Nostr support and a signing pubkey.
    public var supportsZaps: Bool {
        allowsNostr == true && nostrPubkey != nil
    }

    /// Builds the LNURL callback URL that requests a Lightning invoice for a zap.
    ///
    /// The zap request is JSON-encoded and passed as the `nostr` query parameter (NIP-57); the
    /// amount and, optionally, the lnurl are added as parameters. Send a GET to the returned URL —
    /// the endpoint replies with `{"pr": "<bolt11 invoice>"}`.
    /// - Parameters:
    ///   - amountMillisats: The amount in millisatoshis. Should match the zap request's `amount`.
    ///   - zapRequest: The signed kind-9734 zap request.
    ///   - lnurl: The bech32 `lnurl`, added as the `lnurl` parameter when provided.
    /// - Returns: The invoice request URL, or nil if the callback or zap request can't be encoded.
    public func invoiceRequestURL(amountMillisats: Int64, zapRequest: Event, lnurl: String? = nil) -> URL? {
        guard var components = URLComponents(string: callback),
            let zapData = try? JSONEncoder().encode(zapRequest),
            let zapJSON = String(data: zapData, encoding: .utf8),
            let encodedZap = Self.percentEncodedQueryValue(zapJSON)
        else {
            return nil
        }

        // Pre-encode values and set them via percentEncodedQueryItems so URLComponents does not
        // re-encode (and so "+" is escaped to %2B rather than being misread as a space).
        var items = components.percentEncodedQueryItems ?? []
        items.append(URLQueryItem(name: "amount", value: String(amountMillisats)))
        items.append(URLQueryItem(name: "nostr", value: encodedZap))
        if let lnurl, let encodedLnurl = Self.percentEncodedQueryValue(lnurl) {
            items.append(URLQueryItem(name: "lnurl", value: encodedLnurl))
        }
        components.percentEncodedQueryItems = items
        return components.url
    }

    /// Percent-encodes a string for use as a single query-parameter value, escaping the
    /// sub-delimiters that would otherwise be misparsed (`+ & = ? #`).
    private static func percentEncodedQueryValue(_ value: String) -> String? {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&=?#"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
