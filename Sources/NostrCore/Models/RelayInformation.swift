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

    /// The administrator's public key.
    ///
    /// Nil when the document omits it or carries a value that is not a canonical hex public key.
    public var publicKey: PublicKey?

    /// The relay's own independent identity public key (the document's `self` field).
    ///
    /// Nil when the document omits it or carries a value that is not a canonical hex public key.
    public var selfPublicKey: PublicKey?

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
        case publicKey = "pubkey"
        case selfPublicKey = "self"
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

    /// Creates a document from its fields; every field defaults to absent.
    public init(
        name: String? = nil,
        description: String? = nil,
        banner: String? = nil,
        icon: String? = nil,
        publicKey: PublicKey? = nil,
        selfPublicKey: PublicKey? = nil,
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
        self.publicKey = publicKey
        self.selfPublicKey = selfPublicKey
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

// MARK: - Decoding
extension RelayInformation {
    /// Decodes a NIP-11 document.
    ///
    /// The document is written by the relay operator, so the two public keys are read leniently:
    /// a `pubkey` or `self` value that is not a canonical 64-digit lowercase hex public key
    /// decodes as nil instead of failing the whole document. Every other field is decoded strictly.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func lenientPublicKey(_ key: CodingKeys) -> PublicKey? {
            (try? container.decodeIfPresent(String.self, forKey: key))?.flatMap(PublicKey.init)
        }

        self.init(
            name: try container.decodeIfPresent(String.self, forKey: .name),
            description: try container.decodeIfPresent(String.self, forKey: .description),
            banner: try container.decodeIfPresent(String.self, forKey: .banner),
            icon: try container.decodeIfPresent(String.self, forKey: .icon),
            publicKey: lenientPublicKey(.publicKey),
            selfPublicKey: lenientPublicKey(.selfPublicKey),
            contact: try container.decodeIfPresent(String.self, forKey: .contact),
            supportedNIPs: try container.decodeIfPresent([Int].self, forKey: .supportedNIPs),
            software: try container.decodeIfPresent(String.self, forKey: .software),
            version: try container.decodeIfPresent(String.self, forKey: .version),
            termsOfService: try container.decodeIfPresent(String.self, forKey: .termsOfService),
            limitation: try container.decodeIfPresent(Limitation.self, forKey: .limitation),
            relayCountries: try container.decodeIfPresent([String].self, forKey: .relayCountries),
            languageTags: try container.decodeIfPresent([String].self, forKey: .languageTags),
            tags: try container.decodeIfPresent([String].self, forKey: .tags),
            postingPolicy: try container.decodeIfPresent(String.self, forKey: .postingPolicy),
            paymentsURL: try container.decodeIfPresent(String.self, forKey: .paymentsURL),
            fees: try container.decodeIfPresent(Fees.self, forKey: .fees),
            retention: try container.decodeIfPresent([Retention].self, forKey: .retention)
        )
    }
}

// MARK: - Nested Types

extension RelayInformation {
    /// Protocol limitations advertised by a relay (part of NIP-11).
    public struct Limitation: Codable, Sendable, Hashable {
        /// Maximum length, in bytes, of any incoming JSON message the relay accepts
        /// (REQ, EVENT, CLOSE, AUTH, COUNT — not only events).
        public var maximumMessageLength: Int?
        /// Maximum number of concurrent subscriptions allowed on one connection.
        public var maximumSubscriptions: Int?
        /// Maximum number of filters allowed in a single subscription.
        public var maximumFilters: Int?
        /// Maximum value the relay honors for a filter's `limit`.
        public var maximumLimit: Int?
        /// Maximum length of a subscription id.
        public var maximumSubscriptionIDLength: Int?
        /// Maximum number of tags allowed on an event.
        public var maximumEventTags: Int?
        /// Maximum length, in bytes, of an event's `content` field.
        public var maximumContentLength: Int?
        /// Minimum NIP-13 proof-of-work difficulty the relay requires to accept an event.
        public var minimumProofOfWorkDifficulty: Int?
        /// Whether the relay requires NIP-42 authentication before serving requests.
        public var authRequired: Bool?
        /// Whether the relay requires payment to use.
        public var paymentRequired: Bool?
        /// Whether writes are restricted (e.g. to paid or allow-listed public keys).
        public var restrictedWrites: Bool?
        /// How far in the past an event's `created_at` may be, relative to the relay's current
        /// time; older events are rejected.
        public var createdAtLowerLimit: Duration?
        /// How far in the future an event's `created_at` may be, relative to the relay's current
        /// time; events further ahead are rejected.
        public var createdAtUpperLimit: Duration?
        /// Number of events returned when a filter omits an explicit `limit`.
        public var defaultLimit: Int?

        enum CodingKeys: String, CodingKey {
            case maximumMessageLength = "max_message_length"
            case maximumSubscriptions = "max_subscriptions"
            case maximumFilters = "max_filters"
            case maximumLimit = "max_limit"
            case maximumSubscriptionIDLength = "max_subid_length"
            case maximumEventTags = "max_event_tags"
            case maximumContentLength = "max_content_length"
            case minimumProofOfWorkDifficulty = "min_pow_difficulty"
            case authRequired = "auth_required"
            case paymentRequired = "payment_required"
            case restrictedWrites = "restricted_writes"
            case createdAtLowerLimit = "created_at_lower_limit"
            case createdAtUpperLimit = "created_at_upper_limit"
            case defaultLimit = "default_limit"
        }

        public init(
            maximumMessageLength: Int? = nil,
            maximumSubscriptions: Int? = nil,
            maximumFilters: Int? = nil,
            maximumLimit: Int? = nil,
            maximumSubscriptionIDLength: Int? = nil,
            maximumEventTags: Int? = nil,
            maximumContentLength: Int? = nil,
            minimumProofOfWorkDifficulty: Int? = nil,
            authRequired: Bool? = nil,
            paymentRequired: Bool? = nil,
            restrictedWrites: Bool? = nil,
            createdAtLowerLimit: Duration? = nil,
            createdAtUpperLimit: Duration? = nil,
            defaultLimit: Int? = nil
        ) {
            self.maximumMessageLength = maximumMessageLength
            self.maximumSubscriptions = maximumSubscriptions
            self.maximumFilters = maximumFilters
            self.maximumLimit = maximumLimit
            self.maximumSubscriptionIDLength = maximumSubscriptionIDLength
            self.maximumEventTags = maximumEventTags
            self.maximumContentLength = maximumContentLength
            self.minimumProofOfWorkDifficulty = minimumProofOfWorkDifficulty
            self.authRequired = authRequired
            self.paymentRequired = paymentRequired
            self.restrictedWrites = restrictedWrites
            self.createdAtLowerLimit = createdAtLowerLimit
            self.createdAtUpperLimit = createdAtUpperLimit
            self.defaultLimit = defaultLimit
        }

        /// Decodes the limitations, reading the `created_at` limits as integer numbers of seconds.
        /// - Throws: `DecodingError` if a field has the wrong type.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func seconds(_ key: CodingKeys) throws -> Duration? {
                try container.decodeIfPresent(Int64.self, forKey: key).map(Duration.seconds)
            }
            self.init(
                maximumMessageLength: try container.decodeIfPresent(Int.self, forKey: .maximumMessageLength),
                maximumSubscriptions: try container.decodeIfPresent(Int.self, forKey: .maximumSubscriptions),
                maximumFilters: try container.decodeIfPresent(Int.self, forKey: .maximumFilters),
                maximumLimit: try container.decodeIfPresent(Int.self, forKey: .maximumLimit),
                maximumSubscriptionIDLength: try container.decodeIfPresent(
                    Int.self, forKey: .maximumSubscriptionIDLength),
                maximumEventTags: try container.decodeIfPresent(Int.self, forKey: .maximumEventTags),
                maximumContentLength: try container.decodeIfPresent(Int.self, forKey: .maximumContentLength),
                minimumProofOfWorkDifficulty: try container.decodeIfPresent(
                    Int.self, forKey: .minimumProofOfWorkDifficulty),
                authRequired: try container.decodeIfPresent(Bool.self, forKey: .authRequired),
                paymentRequired: try container.decodeIfPresent(Bool.self, forKey: .paymentRequired),
                restrictedWrites: try container.decodeIfPresent(Bool.self, forKey: .restrictedWrites),
                createdAtLowerLimit: try seconds(.createdAtLowerLimit),
                createdAtUpperLimit: try seconds(.createdAtUpperLimit),
                defaultLimit: try container.decodeIfPresent(Int.self, forKey: .defaultLimit))
        }

        /// Encodes the limitations, writing the `created_at` limits as whole seconds truncated
        /// toward zero.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(maximumMessageLength, forKey: .maximumMessageLength)
            try container.encodeIfPresent(maximumSubscriptions, forKey: .maximumSubscriptions)
            try container.encodeIfPresent(maximumFilters, forKey: .maximumFilters)
            try container.encodeIfPresent(maximumLimit, forKey: .maximumLimit)
            try container.encodeIfPresent(maximumSubscriptionIDLength, forKey: .maximumSubscriptionIDLength)
            try container.encodeIfPresent(maximumEventTags, forKey: .maximumEventTags)
            try container.encodeIfPresent(maximumContentLength, forKey: .maximumContentLength)
            try container.encodeIfPresent(minimumProofOfWorkDifficulty, forKey: .minimumProofOfWorkDifficulty)
            try container.encodeIfPresent(authRequired, forKey: .authRequired)
            try container.encodeIfPresent(paymentRequired, forKey: .paymentRequired)
            try container.encodeIfPresent(restrictedWrites, forKey: .restrictedWrites)
            try container.encodeIfPresent(createdAtLowerLimit?.wholeSeconds, forKey: .createdAtLowerLimit)
            try container.encodeIfPresent(createdAtUpperLimit?.wholeSeconds, forKey: .createdAtUpperLimit)
            try container.encodeIfPresent(defaultLimit, forKey: .defaultLimit)
        }
    }

    /// Fee schedules for admission, subscription, and publication.
    public struct Fees: Codable, Sendable, Hashable {
        /// One-time fees charged to be admitted to the relay.
        public var admission: [FeeSchedule]?
        /// Recurring fees charged per subscription period.
        public var subscription: [FeeSchedule]?
        /// Fees charged to publish events, optionally scoped to specific kinds.
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

        /// How long one payment lasts (for subscriptions).
        public var period: Duration?

        /// Event kinds this fee applies to (for publication).
        public var kinds: [Int]?

        enum CodingKeys: String, CodingKey {
            case amount
            case unit
            case period
            case kinds
        }

        /// Creates a fee entry.
        /// - Parameters:
        ///   - amount: The amount of the fee, in `unit`.
        ///   - unit: The unit of the amount, e.g. "msats".
        ///   - period: How long one payment lasts, for subscriptions; sent as whole seconds.
        ///   - kinds: The event kinds the fee applies to, for publication.
        public init(
            amount: Int? = nil,
            unit: String? = nil,
            period: Duration? = nil,
            kinds: [Int]? = nil
        ) {
            self.amount = amount
            self.unit = unit
            self.period = period
            self.kinds = kinds
        }

        /// Decodes the fee entry, reading `period` as an integer number of seconds.
        /// - Throws: `DecodingError` if a field has the wrong type.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                amount: try container.decodeIfPresent(Int.self, forKey: .amount),
                unit: try container.decodeIfPresent(String.self, forKey: .unit),
                period: try container.decodeIfPresent(Int.self, forKey: .period).map(Duration.seconds),
                kinds: try container.decodeIfPresent([Int].self, forKey: .kinds))
        }

        /// Encodes the fee entry, writing `period` as whole seconds truncated toward zero.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(amount, forKey: .amount)
            try container.encodeIfPresent(unit, forKey: .unit)
            try container.encodeIfPresent(period?.wholeSeconds, forKey: .period)
            try container.encodeIfPresent(kinds, forKey: .kinds)
        }
    }

    /// A retention policy entry.
    public struct Retention: Codable, Sendable, Hashable {
        /// Event kinds this retention policy applies to. Omit to apply to all kinds.
        public var kinds: [KindSpec]?

        /// How long matching events are kept: `.zero` means they are not stored at all, and `nil`
        /// means there is no time limit.
        public var time: Duration?

        /// Maximum number of events retained.
        public var count: Int?

        enum CodingKeys: String, CodingKey {
            case kinds
            case time
            case count
        }

        /// Creates a retention policy entry.
        /// - Parameters:
        ///   - kinds: The event kinds the policy applies to, or `nil` for all kinds.
        ///   - time: How long matching events are kept — `.zero` for not at all, `nil` for no time
        ///     limit; sent as whole seconds.
        ///   - count: The maximum number of events retained.
        public init(
            kinds: [KindSpec]? = nil,
            time: Duration? = nil,
            count: Int? = nil
        ) {
            self.kinds = kinds
            self.time = time
            self.count = count
        }

        /// Decodes the retention entry, reading `time` as an integer number of seconds.
        /// - Throws: `DecodingError` if a field has the wrong type.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                kinds: try container.decodeIfPresent([KindSpec].self, forKey: .kinds),
                time: try container.decodeIfPresent(Int.self, forKey: .time).map(Duration.seconds),
                count: try container.decodeIfPresent(Int.self, forKey: .count))
        }

        /// Encodes the retention entry, writing `time` as whole seconds truncated toward zero.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(kinds, forKey: .kinds)
            try container.encodeIfPresent(time?.wholeSeconds, forKey: .time)
            try container.encodeIfPresent(count, forKey: .count)
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

        public init(from decoder: any Decoder) throws {
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

        public func encode(to encoder: any Encoder) throws {
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
        /// A lower-level network error occurred.
        case networkError(String)

        /// The relay returned a non-2xx HTTP response.
        case invalidResponse

        /// The response body could not be decoded as a NIP-11 document.
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
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
    /// Converts a relay URL to the HTTP(S) URL used for NIP-11 queries.
    ///
    /// - `wss://` becomes `https://`
    /// - `ws://` becomes `http://`
    ///
    /// The host, port, path, and query are preserved.
    public static func informationURL(from relayURL: RelayURL) -> URL {
        var components = URLComponents(url: relayURL.url, resolvingAgainstBaseURL: false)
        components?.scheme = relayURL.url.scheme == "wss" ? "https" : "http"
        // Unreachable fallback: a relay URL always has a ws or wss scheme and a host.
        return components?.url ?? relayURL.url
    }

    /// Fetches the NIP-11 Information Document for a relay.
    ///
    /// - Parameters:
    ///   - relayURL: The relay's URL.
    ///   - urlSession: The URL session to use (defaults to `.shared`).
    /// - Returns: The decoded ``RelayInformation``.
    /// - Throws: ``FetchError`` if the network request fails or the response cannot be decoded.
    public static func fetch(
        from relayURL: RelayURL,
        urlSession: URLSession = .shared
    ) async throws -> RelayInformation {
        var request = URLRequest(url: informationURL(from: relayURL))
        request.httpMethod = "GET"
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")

        let data: Data
        let urlResponse: URLResponse
        do {
            (data, urlResponse) = try await urlSession.data(for: request)
        } catch {
            // Surface cancellation as CancellationError; wrap everything else so no raw error leaks
            // past the typed FetchError. URLSession reports task cancellation as URLError(.cancelled).
            if error is CancellationError {
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
}
