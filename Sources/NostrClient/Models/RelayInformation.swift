import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Relay Information Document (NIP-11)
/// https://github.com/nostr-protocol/nips/blob/master/11.md
///
/// Describes a relay's capabilities, limitations, and metadata. Fetched from
/// a relay by sending an HTTP GET request to its URL (with the scheme
/// converted from `wss://`/`ws://` to `https://`/`http://`) with an
/// `Accept: application/nostr+json` header.
///
/// All fields are optional because relays implement NIP-11 to varying degrees.
public struct RelayInformation: Codable, Sendable, Hashable {
    /// A human-readable name for the relay.
    public var name: String?

    /// A long-form description of the relay.
    public var description: String?

    /// URL to a banner image for the relay.
    public var banner: String?

    /// URL to an icon image for the relay (preferably square).
    public var icon: String?

    /// Administrator's public key (32-byte hex).
    public var pubkey: String?

    /// The relay's own independent identity public key (32-byte hex).
    public var selfPubkey: String?

    /// Administrator's contact (URI, e.g. `mailto:` or `https://`).
    public var contact: String?

    /// List of NIP numbers supported by this relay.
    public var supportedNIPs: [Int]?

    /// Project homepage URL for the relay software.
    public var software: String?

    /// Version string or commit identifier.
    public var version: String?

    /// URL to the relay's terms of service.
    public var termsOfService: String?

    /// Protocol-level limitations advertised by the relay.
    public var limitation: Limitation?

    /// ISO 3166-1 alpha-2 country codes where the relay is located.
    public var relayCountries: [String]?

    /// BCP 47 language tags for the relay's primary content languages.
    public var languageTags: [String]?

    /// Free-form topical tags (e.g. "sfw-only", "bitcoin").
    public var tags: [String]?

    /// URL to a posting policy document.
    public var postingPolicy: String?

    /// URL where users can make payments to the relay.
    public var paymentsURL: String?

    /// Fee schedules advertised by the relay.
    public var fees: Fees?

    /// Retention policies advertised by the relay.
    public var retention: [Retention]?

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case banner
        case icon
        case pubkey
        case selfPubkey = "self"
        case contact
        case supportedNIPs = "supported_nips"
        case software
        case version
        case termsOfService = "terms_of_service"
        case limitation
        case relayCountries = "relay_countries"
        case languageTags = "language_tags"
        case tags
        case postingPolicy = "posting_policy"
        case paymentsURL = "payments_url"
        case fees
        case retention
    }

    public init(
        name: String? = nil,
        description: String? = nil,
        banner: String? = nil,
        icon: String? = nil,
        pubkey: String? = nil,
        selfPubkey: String? = nil,
        contact: String? = nil,
        supportedNIPs: [Int]? = nil,
        software: String? = nil,
        version: String? = nil,
        termsOfService: String? = nil,
        limitation: Limitation? = nil,
        relayCountries: [String]? = nil,
        languageTags: [String]? = nil,
        tags: [String]? = nil,
        postingPolicy: String? = nil,
        paymentsURL: String? = nil,
        fees: Fees? = nil,
        retention: [Retention]? = nil
    ) {
        self.name = name
        self.description = description
        self.banner = banner
        self.icon = icon
        self.pubkey = pubkey
        self.selfPubkey = selfPubkey
        self.contact = contact
        self.supportedNIPs = supportedNIPs
        self.software = software
        self.version = version
        self.termsOfService = termsOfService
        self.limitation = limitation
        self.relayCountries = relayCountries
        self.languageTags = languageTags
        self.tags = tags
        self.postingPolicy = postingPolicy
        self.paymentsURL = paymentsURL
        self.fees = fees
        self.retention = retention
    }
}

// MARK: - Nested Types

extension RelayInformation {
    /// Protocol limitations advertised by a relay (part of NIP-11).
    public struct Limitation: Codable, Sendable, Hashable {
        public var maxMessageLength: Int?
        public var maxSubscriptions: Int?
        public var maxFilters: Int?
        public var maxLimit: Int?
        public var maxSubidLength: Int?
        public var maxEventTags: Int?
        public var maxContentLength: Int?
        public var minPowDifficulty: Int?
        public var authRequired: Bool?
        public var paymentRequired: Bool?
        public var restrictedWrites: Bool?
        public var createdAtLowerLimit: Int64?
        public var createdAtUpperLimit: Int64?
        public var defaultLimit: Int?

        enum CodingKeys: String, CodingKey {
            case maxMessageLength = "max_message_length"
            case maxSubscriptions = "max_subscriptions"
            case maxFilters = "max_filters"
            case maxLimit = "max_limit"
            case maxSubidLength = "max_subid_length"
            case maxEventTags = "max_event_tags"
            case maxContentLength = "max_content_length"
            case minPowDifficulty = "min_pow_difficulty"
            case authRequired = "auth_required"
            case paymentRequired = "payment_required"
            case restrictedWrites = "restricted_writes"
            case createdAtLowerLimit = "created_at_lower_limit"
            case createdAtUpperLimit = "created_at_upper_limit"
            case defaultLimit = "default_limit"
        }

        public init(
            maxMessageLength: Int? = nil,
            maxSubscriptions: Int? = nil,
            maxFilters: Int? = nil,
            maxLimit: Int? = nil,
            maxSubidLength: Int? = nil,
            maxEventTags: Int? = nil,
            maxContentLength: Int? = nil,
            minPowDifficulty: Int? = nil,
            authRequired: Bool? = nil,
            paymentRequired: Bool? = nil,
            restrictedWrites: Bool? = nil,
            createdAtLowerLimit: Int64? = nil,
            createdAtUpperLimit: Int64? = nil,
            defaultLimit: Int? = nil
        ) {
            self.maxMessageLength = maxMessageLength
            self.maxSubscriptions = maxSubscriptions
            self.maxFilters = maxFilters
            self.maxLimit = maxLimit
            self.maxSubidLength = maxSubidLength
            self.maxEventTags = maxEventTags
            self.maxContentLength = maxContentLength
            self.minPowDifficulty = minPowDifficulty
            self.authRequired = authRequired
            self.paymentRequired = paymentRequired
            self.restrictedWrites = restrictedWrites
            self.createdAtLowerLimit = createdAtLowerLimit
            self.createdAtUpperLimit = createdAtUpperLimit
            self.defaultLimit = defaultLimit
        }
    }

    /// Fee schedules for admission, subscription, and publication.
    public struct Fees: Codable, Sendable, Hashable {
        public var admission: [FeeSchedule]?
        public var subscription: [FeeSchedule]?
        public var publication: [FeeSchedule]?

        public init(
            admission: [FeeSchedule]? = nil,
            subscription: [FeeSchedule]? = nil,
            publication: [FeeSchedule]? = nil
        ) {
            self.admission = admission
            self.subscription = subscription
            self.publication = publication
        }
    }

    /// A single fee entry within a fee schedule.
    public struct FeeSchedule: Codable, Sendable, Hashable {
        /// Amount of the fee (in `unit`).
        public var amount: Int?

        /// Unit of the amount (e.g. "msats").
        public var unit: String?

        /// Period in seconds (for subscriptions).
        public var period: Int?

        /// Event kinds this fee applies to (for publication).
        public var kinds: [Int]?

        public init(
            amount: Int? = nil,
            unit: String? = nil,
            period: Int? = nil,
            kinds: [Int]? = nil
        ) {
            self.amount = amount
            self.unit = unit
            self.period = period
            self.kinds = kinds
        }
    }

    /// A retention policy entry.
    public struct Retention: Codable, Sendable, Hashable {
        /// Event kinds this retention policy applies to. Omit to apply to all kinds.
        public var kinds: [KindSpec]?

        /// Retention time in seconds. 0 means "never retained".
        public var time: Int?

        /// Maximum number of events retained.
        public var count: Int?

        public init(
            kinds: [KindSpec]? = nil,
            time: Int? = nil,
            count: Int? = nil
        ) {
            self.kinds = kinds
            self.time = time
            self.count = count
        }
    }

    /// Specifies an event kind — either a single kind or an inclusive range of kinds.
    ///
    /// NIP-11 allows the `kinds` array in a retention entry to mix single
    /// integers and two-element arrays, e.g. `[0, 1, [5, 7]]`.
    public enum KindSpec: Codable, Sendable, Hashable {
        /// A single event kind.
        case single(Int)

        /// An inclusive range `[lower, upper]` of event kinds.
        case range(Int, Int)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(Int.self) {
                self = .single(value)
                return
            }
            if let array = try? container.decode([Int].self), array.count == 2 {
                self = .range(array[0], array[1])
                return
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "KindSpec must be an integer or a two-element integer array"
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .single(let value):
                try container.encode(value)
            case .range(let lower, let upper):
                try container.encode([lower, upper])
            }
        }
    }
}

// MARK: - Fetch Errors

extension RelayInformation {
    /// Errors that can occur while fetching a NIP-11 information document.
    public enum FetchError: Error, LocalizedError, Sendable, Equatable {
        /// The relay URL was malformed, or its scheme was not `ws` or `wss`.
        case invalidRelayURL(String)

        /// A lower-level network error occurred.
        case networkError(String)

        /// The relay returned a non-2xx HTTP response.
        case invalidResponse

        /// The response body could not be decoded as a NIP-11 document.
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidRelayURL(let reason):
                return "Invalid relay URL: \(reason)"
            case .networkError(let message):
                return "Network error: \(message)"
            case .invalidResponse:
                return "Invalid response from relay"
            case .decodingFailed(let reason):
                return "Failed to decode relay information: \(reason)"
            }
        }
    }
}

// MARK: - Fetching

extension RelayInformation {
    /// Converts a relay WebSocket URL to the HTTP(S) URL used for NIP-11 queries.
    ///
    /// - `wss://` becomes `https://`
    /// - `ws://` becomes `http://`
    /// - Any other scheme returns `nil`
    ///
    /// The host, port, path, and query are preserved.
    public static func informationURL(from relayURL: URL) -> URL? {
        guard var components = URLComponents(url: relayURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            return nil
        }
        return components.url
    }

    /// Fetches the NIP-11 Information Document for a relay.
    ///
    /// - Parameters:
    ///   - relayURL: The relay WebSocket URL (`wss://` or `ws://`).
    ///   - urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The decoded ``RelayInformation``.
    /// - Throws: ``FetchError`` if the URL is invalid, the network request
    ///   fails, or the response cannot be decoded.
    public static func fetch(
        from relayURL: URL,
        urlSession: URLSession = .shared
    ) async throws -> RelayInformation {
        guard let httpURL = informationURL(from: relayURL) else {
            throw FetchError.invalidRelayURL(relayURL.absoluteString)
        }

        var request = URLRequest(url: httpURL)
        request.httpMethod = "GET"
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw error
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw FetchError.networkError(error.localizedDescription)
        }

        guard let httpResponse = urlResponse as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
        else {
            throw FetchError.invalidResponse
        }

        do {
            return try JSONDecoder().decode(RelayInformation.self, from: data)
        } catch {
            throw FetchError.decodingFailed(String(describing: error))
        }
    }

    /// Fetches the NIP-11 Information Document for a relay given its URL string.
    ///
    /// - Parameters:
    ///   - urlString: The relay WebSocket URL string.
    ///   - urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The decoded ``RelayInformation``.
    /// - Throws: ``FetchError`` if the URL is invalid, the network request
    ///   fails, or the response cannot be decoded.
    public static func fetch(
        fromRelayURLString urlString: String,
        urlSession: URLSession = .shared
    ) async throws -> RelayInformation {
        guard let url = URL(string: urlString) else {
            throw FetchError.invalidRelayURL(urlString)
        }
        return try await fetch(from: url, urlSession: urlSession)
    }
}
