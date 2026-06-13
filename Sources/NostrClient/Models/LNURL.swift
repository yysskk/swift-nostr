import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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

/// The response from an LNURL-pay callback: the bolt11 invoice to pay for a zap (NIP-57).
public struct LNURLInvoiceResponse: Decodable, Sendable, Hashable {
    /// The bolt11 Lightning invoice to pay (the `pr`, or "payment request", field).
    public let pr: String

    public init(pr: String) {
        self.pr = pr
    }
}

// MARK: - Invoice Fetching

extension LNURLPayResponse {
    /// Errors that can occur while fetching a Lightning invoice from the LNURL callback.
    public enum InvoiceError: Error, LocalizedError, Sendable, Equatable {
        /// The amount is outside the endpoint's `minSendable...maxSendable` range (millisatoshis).
        case amountOutOfRange(min: Int64, max: Int64)

        /// The callback or zap request could not be encoded into an invoice request URL.
        case invalidCallbackURL

        /// A lower-level network error occurred.
        case networkError(String)

        /// The endpoint returned a non-2xx response, or a body that was not a valid invoice.
        case invalidResponse

        /// The endpoint returned an LNURL error response (`{"status":"ERROR","reason":...}`).
        case lnurlError(String)

        public var errorDescription: String? {
            switch self {
            case .amountOutOfRange(let min, let max):
                return "Amount is outside the endpoint's range (\(min)...\(max) msats)"
            case .invalidCallbackURL:
                return "Could not build the invoice request URL"
            case .networkError(let message):
                return "Network error: \(message)"
            case .invalidResponse:
                return "Invalid response from the LNURL endpoint"
            case .lnurlError(let reason):
                return "LNURL endpoint error: \(reason)"
            }
        }
    }

    /// Fetches a Lightning invoice for a zap from this endpoint's callback.
    ///
    /// Validates that `amountMillisats` is within `minSendable...maxSendable`, builds the request
    /// with ``invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``, sends a GET, and returns the
    /// bolt11 invoice from the `{"pr": "<bolt11>"}` response. Pay the returned invoice to complete
    /// the zap; the recipient's wallet then publishes the kind-9735 zap receipt.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - amountMillisats: The amount in millisatoshis. Must be within `minSendable...maxSendable`.
    ///   - zapRequest: The signed kind-9734 zap request.
    ///   - lnurl: The bech32 `lnurl`, forwarded as the `lnurl` parameter when provided.
    ///   - urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The bolt11 Lightning invoice to pay.
    /// - Throws: ``InvoiceError`` if the amount is out of range, the request cannot be built, the
    ///   network request fails, or the endpoint returns an error.
    public func fetchInvoice(
        amountMillisats: Int64,
        zapRequest: Event,
        lnurl: String? = nil,
        urlSession: URLSession = .shared
    ) async throws -> String {
        // Explicit comparisons rather than `(minSendable...maxSendable).contains(_:)` — a malformed
        // response with minSendable > maxSendable would trap when constructing the range.
        guard amountMillisats >= minSendable, amountMillisats <= maxSendable else {
            throw InvoiceError.amountOutOfRange(min: minSendable, max: maxSendable)
        }
        guard
            let url = invoiceRequestURL(amountMillisats: amountMillisats, zapRequest: zapRequest, lnurl: lnurl)
        else {
            throw InvoiceError.invalidCallbackURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            // Surface cancellation as CancellationError; wrap everything else so no raw error leaks
            // past the typed InvoiceError. URLSession reports task cancellation as URLError(.cancelled).
            if error is CancellationError {
                throw error
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw InvoiceError.networkError(error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw InvoiceError.invalidResponse
        }

        // An LNURL endpoint can return an error object ({"status":"ERROR","reason":...}) even with a
        // 2xx status, so surface that before trying to decode the invoice.
        if let status = try? JSONDecoder().decode(LNURLStatusResponse.self, from: data),
            status.status.uppercased() == "ERROR"
        {
            throw InvoiceError.lnurlError(status.reason ?? "unknown error")
        }

        guard let invoice = try? JSONDecoder().decode(LNURLInvoiceResponse.self, from: data) else {
            throw InvoiceError.invalidResponse
        }
        return invoice.pr
    }
}

/// The error shape an LNURL endpoint returns: `{"status":"ERROR","reason":"..."}` (LUD-06).
private struct LNURLStatusResponse: Decodable {
    let status: String
    let reason: String?
}
