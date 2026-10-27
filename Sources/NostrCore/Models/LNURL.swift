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
    /// - Throws: ``LNURL/Error/invalidBech32(_:)`` if the string is not valid bech32,
    ///   ``LNURL/Error/unexpectedPrefix(_:)`` if its prefix is not `lnurl`, or
    ///   ``LNURL/Error/invalidURL`` if its payload is not a UTF-8 URL.
    public static func decode(_ lnurl: String) throws(LNURL.Error) -> URL {
        let decoded: (hrp: String, data: Data)
        do throws(Bech32.Error) {
            decoded = try Bech32.decode(lnurl)
        } catch {
            throw .invalidBech32(error)
        }
        guard decoded.hrp == "lnurl" else {
            throw .unexpectedPrefix(decoded.hrp)
        }
        guard let string = String(data: decoded.data, encoding: .utf8), let url = URL(string: string) else {
            throw .invalidURL
        }
        return url
    }

    /// Encodes a URL as a bech32 `lnurl` string, as used in a zap request's `lnurl` tag.
    public static func encode(_ url: URL) -> String {
        Bech32.encode(validatedHRP: "lnurl", data: Data(url.absoluteString.utf8))
    }

    /// Why a string could not be decoded as an `lnurl`.
    public enum Error: Swift.Error, LocalizedError, Sendable, Equatable {
        /// The string is not valid bech32.
        case invalidBech32(Bech32.Error)
        /// The bech32 string carries a prefix other than `lnurl` (payload: the prefix found).
        case unexpectedPrefix(String)
        /// The decoded payload is not a UTF-8 URL.
        case invalidURL

        public var errorDescription: String? {
            switch self {
            case .invalidBech32(let error):
                return "Invalid lnurl: \(error.errorDescription ?? "invalid bech32")"
            case .unexpectedPrefix(let prefix):
                return "Expected an lnurl, got bech32 prefix \(prefix)"
            case .invalidURL:
                return "The lnurl does not encode a URL"
            }
        }
    }
}

/// An LNURL-pay service response — the JSON returned by an LNURL-pay endpoint, with the fields
/// NIP-57 zaps rely on. Decode the endpoint's response into this, then build an invoice request
/// with ``invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``.
public struct LNURLPayResponse: Decodable, Sendable, Hashable {
    /// The URL to send the zap request / invoice request to.
    public let callback: URL

    /// Minimum payable amount in millisatoshis.
    public let minimumSendable: Int64

    /// Maximum payable amount in millisatoshis.
    public let maximumSendable: Int64

    /// Whether the endpoint supports Nostr zaps.
    public let allowsNostr: Bool?

    /// The public key the endpoint uses to sign kind-9735 zap receipts.
    ///
    /// Nil when the response omits it or carries a value that is not a canonical hex public key,
    /// so such an endpoint does not ``supportsZaps``.
    public let nostrPublicKey: PublicKey?

    /// The maximum comment length the endpoint accepts, if it accepts comments.
    public let commentAllowed: Int?

    /// Creates a response from its fields, e.g. for tests or a cached endpoint.
    public init(
        callback: URL,
        minimumSendable: Int64,
        maximumSendable: Int64,
        allowsNostr: Bool? = nil,
        nostrPublicKey: PublicKey? = nil,
        commentAllowed: Int? = nil
    ) {
        self.callback = callback
        self.minimumSendable = minimumSendable
        self.maximumSendable = maximumSendable
        self.allowsNostr = allowsNostr
        self.nostrPublicKey = nostrPublicKey
        self.commentAllowed = commentAllowed
    }

    private enum CodingKeys: String, CodingKey {
        case callback, allowsNostr, commentAllowed
        case minimumSendable = "minSendable"
        case maximumSendable = "maxSendable"
        case nostrPublicKey = "nostrPubkey"
    }

    /// Decodes an LNURL-pay response.
    ///
    /// The response comes from a third-party endpoint, so `nostrPublicKey` is read leniently: a value
    /// that is not a canonical 64-digit lowercase hex public key decodes as nil rather than failing
    /// the whole response. Every other field is decoded strictly.
    /// - Throws: `DecodingError` if a field has the wrong type, or `callback` is missing or not a URL.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let callback = try container.decode(String.self, forKey: .callback)
        guard let callbackURL = URL(string: callback) else {
            throw DecodingError.dataCorruptedError(
                forKey: .callback, in: container, debugDescription: "callback is not a URL: \(callback)")
        }
        self.init(
            callback: callbackURL,
            minimumSendable: try container.decode(Int64.self, forKey: .minimumSendable),
            maximumSendable: try container.decode(Int64.self, forKey: .maximumSendable),
            allowsNostr: try container.decodeIfPresent(Bool.self, forKey: .allowsNostr),
            nostrPublicKey: (try? container.decodeIfPresent(String.self, forKey: .nostrPublicKey))?
                .flatMap(PublicKey.init),
            commentAllowed: try container.decodeIfPresent(Int.self, forKey: .commentAllowed)
        )
    }

    /// Whether this endpoint can receive zaps: it advertises Nostr support and a signing public key.
    public var supportsZaps: Bool {
        allowsNostr == true && nostrPublicKey != nil
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
        guard var components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
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
        if let lnurl, let encodedLNURL = Self.percentEncodedQueryValue(lnurl) {
            items.append(URLQueryItem(name: "lnurl", value: encodedLNURL))
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
        /// The amount is outside the endpoint's `minimumSendable...maximumSendable` range
        /// (millisatoshis).
        case amountOutOfRange(minimum: Int64, maximum: Int64)

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
            case .amountOutOfRange(let minimum, let maximum):
                return "Amount is outside the endpoint's range (\(minimum)...\(maximum) msats)"
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
    /// Validates that `amountMillisats` is within `minimumSendable...maximumSendable`, builds the
    /// request with ``invoiceRequestURL(amountMillisats:zapRequest:lnurl:)``, sends a GET, and
    /// returns the bolt11 invoice from the `{"pr": "<bolt11>"}` response. Pay the returned invoice
    /// to complete the zap; the recipient's wallet then publishes the kind-9735 zap receipt.
    /// https://github.com/nostr-protocol/nips/blob/master/57.md
    /// - Parameters:
    ///   - amountMillisats: The amount in millisatoshis. Must be within
    ///     `minimumSendable...maximumSendable`.
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
        // Explicit comparisons rather than `(minimumSendable...maximumSendable).contains(_:)` — a
        // malformed response with minimumSendable > maximumSendable would trap when constructing
        // the range.
        guard amountMillisats >= minimumSendable, amountMillisats <= maximumSendable else {
            throw InvoiceError.amountOutOfRange(minimum: minimumSendable, maximum: maximumSendable)
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
