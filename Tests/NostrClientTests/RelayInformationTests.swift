import Foundation
import NostrCore
import NostrTestSupport
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@Suite("RelayInformation Tests (NIP-11)", .serialized)
struct RelayInformationTests {

    // MARK: - URL Conversion Tests

    @Test("Convert wss to https")
    func convertWssToHttps() {
        let relayURL = RelayURL("wss://relay.example.com")!
        let httpURL = RelayInformation.informationURL(from: relayURL)

        #expect(httpURL.absoluteString == "https://relay.example.com")
    }

    @Test("Convert ws to http")
    func convertWsToHttp() {
        let relayURL = RelayURL("ws://localhost:7777")!
        let httpURL = RelayInformation.informationURL(from: relayURL)

        #expect(httpURL.absoluteString == "http://localhost:7777")
    }

    @Test("Preserve path and port")
    func preservePathAndPort() {
        let relayURL = RelayURL("wss://relay.example.com:8443/nostr")!
        let httpURL = RelayInformation.informationURL(from: relayURL)

        #expect(httpURL.absoluteString == "https://relay.example.com:8443/nostr")
    }

    @Test("Preserve query string")
    func preserveQueryString() {
        let relayURL = RelayURL("wss://relay.example.com/ws?token=abc")!
        let httpURL = RelayInformation.informationURL(from: relayURL)

        #expect(httpURL.absoluteString == "https://relay.example.com/ws?token=abc")
    }

    @Test("Uppercase scheme and host are normalized")
    func uppercaseSchemeNormalized() throws {
        let relayURL = try RelayURL(string: "WSS://Relay.Example.com/")
        let httpURL = RelayInformation.informationURL(from: relayURL)

        #expect(httpURL.absoluteString == "https://relay.example.com")
    }

    // MARK: - JSON Decoding Tests

    @Test("Decode minimal document")
    func decodeMinimalDocument() throws {
        let json = Data("{}".utf8)
        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.name == nil)
        #expect(info.supportedNIPs == nil)
        #expect(info.limitation == nil)
        #expect(info.fees == nil)
        #expect(info.retention == nil)
    }

    @Test("Decode partial document")
    func decodePartialDocument() throws {
        let json = Data(#"{"name":"Example","supported_nips":[1,2,11]}"#.utf8)
        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.name == "Example")
        #expect(info.supportedNIPs == [1, 2, 11])
        #expect(info.description == nil)
    }

    @Test("Decode snake_case top-level fields")
    func decodeSnakeCaseTopLevel() throws {
        let admin = PublicKey.fixture("admin")
        let relay = PublicKey.fixture("relay")
        let json = Data(
            #"""
            {
              "name": "Test Relay",
              "description": "A test relay",
              "pubkey": "\#(admin.hex)",
              "self": "\#(relay.hex)",
              "contact": "mailto:admin@example.com",
              "supported_nips": [1, 2, 11],
              "software": "https://example.com/relay",
              "version": "1.0.0",
              "terms_of_service": "https://example.com/tos",
              "relay_countries": ["US", "JP"],
              "language_tags": ["en", "ja"],
              "tags": ["sfw-only", "bitcoin"],
              "posting_policy": "https://example.com/policy",
              "payments_url": "https://example.com/pay"
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.name == "Test Relay")
        #expect(info.description == "A test relay")
        #expect(info.publicKey == admin)
        #expect(info.selfPublicKey == relay)
        #expect(info.contact == "mailto:admin@example.com")
        #expect(info.supportedNIPs == [1, 2, 11])
        #expect(info.software == "https://example.com/relay")
        #expect(info.version == "1.0.0")
        #expect(info.termsOfService == "https://example.com/tos")
        #expect(info.relayCountries == ["US", "JP"])
        #expect(info.languageTags == ["en", "ja"])
        #expect(info.tags == ["sfw-only", "bitcoin"])
        #expect(info.postingPolicy == "https://example.com/policy")
        #expect(info.paymentsURL == "https://example.com/pay")
    }

    /// The document is written by the relay operator, so a malformed key must not cost the caller
    /// the rest of it — the relay's limits and supported NIPs are what a client actually needs.
    @Test(
        "Malformed public key and self values decode as nil without failing the document",
        arguments: [#""abc123""#, #""\#(String(repeating: "A", count: 64))""#, "42", "null"])
    func decodeMalformedPublicKeysLeniently(value: String) throws {
        let json = Data(
            #"""
            {
              "name": "Test Relay",
              "pubkey": \#(value),
              "self": \#(value),
              "supported_nips": [1, 11],
              "limitation": { "auth_required": true }
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.publicKey == nil)
        #expect(info.selfPublicKey == nil)
        #expect(info.name == "Test Relay")
        #expect(info.supportedNIPs == [1, 11])
        #expect(info.limitation?.authRequired == true)
    }

    @Test("Public keys encode as their hex strings")
    func encodePublicKeysAsHex() throws {
        let admin = PublicKey.fixture("admin")
        let info = RelayInformation(name: "Test Relay", publicKey: admin, selfPublicKey: admin)

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any])

        #expect(object["pubkey"] as? String == admin.hex)
        #expect(object["self"] as? String == admin.hex)
        #expect(try JSONDecoder().decode(RelayInformation.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test("Decode limitation fields")
    func decodeLimitation() throws {
        let json = Data(
            #"""
            {
              "limitation": {
                "max_message_length": 16384,
                "max_subscriptions": 20,
                "max_filters": 100,
                "max_limit": 5000,
                "max_subid_length": 100,
                "max_event_tags": 100,
                "max_content_length": 8196,
                "min_pow_difficulty": 30,
                "auth_required": true,
                "payment_required": false,
                "restricted_writes": true,
                "created_at_lower_limit": 31536000,
                "created_at_upper_limit": 3,
                "default_limit": 500
              }
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)
        let limitation = try #require(info.limitation)

        #expect(limitation.maximumMessageLength == 16384)
        #expect(limitation.maximumSubscriptions == 20)
        #expect(limitation.maximumFilters == 100)
        #expect(limitation.maximumLimit == 5000)
        #expect(limitation.maximumSubscriptionIDLength == 100)
        #expect(limitation.maximumEventTags == 100)
        #expect(limitation.maximumContentLength == 8196)
        #expect(limitation.minimumProofOfWorkDifficulty == 30)
        #expect(limitation.authRequired == true)
        #expect(limitation.paymentRequired == false)
        #expect(limitation.restrictedWrites == true)
        #expect(limitation.createdAtLowerLimit == .seconds(31_536_000))
        #expect(limitation.createdAtUpperLimit == .seconds(3))
        #expect(limitation.defaultLimit == 500)
    }

    @Test("Encode limitation bounds under their NIP-11 keys")
    func encodeLimitationKeys() throws {
        let limitation = RelayInformation.Limitation(
            maximumMessageLength: 16384,
            maximumSubscriptions: 20,
            maximumFilters: 100,
            maximumLimit: 5000,
            maximumSubscriptionIDLength: 64,
            maximumEventTags: 2000,
            maximumContentLength: 8196,
            minimumProofOfWorkDifficulty: 30
        )

        let data = try JSONEncoder().encode(limitation)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(
            object == [
                "max_message_length": 16384,
                "max_subscriptions": 20,
                "max_filters": 100,
                "max_limit": 5000,
                "max_subid_length": 64,
                "max_event_tags": 2000,
                "max_content_length": 8196,
                "min_pow_difficulty": 30,
            ])
        #expect(try JSONDecoder().decode(RelayInformation.Limitation.self, from: data) == limitation)
    }

    @Test("created_at limits are relative offsets that round-trip as integer seconds")
    func createdAtLimitsRoundTrip() throws {
        let limitation = RelayInformation.Limitation(
            createdAtLowerLimit: .seconds(94_608_000), createdAtUpperLimit: .milliseconds(900_500))

        let data = try JSONEncoder().encode(limitation)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["created_at_lower_limit"] as? Int == 94_608_000)
        #expect(object["created_at_upper_limit"] as? Int == 900)

        let decoded = try JSONDecoder().decode(RelayInformation.Limitation.self, from: data)
        #expect(decoded.createdAtLowerLimit == .seconds(94_608_000))
        #expect(decoded.createdAtUpperLimit == .seconds(900))
    }

    @Test("a non-integer created_at limit fails decoding", arguments: ["1.5", "\"60\""])
    func nonIntegerCreatedAtLimitFails(value: String) {
        let json = Data(#"{"created_at_lower_limit":\#(value)}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RelayInformation.Limitation.self, from: json)
        }
    }

    @Test("Decode fees with all categories")
    func decodeFees() throws {
        let json = Data(
            #"""
            {
              "fees": {
                "admission": [{"amount": 1000000, "unit": "msats"}],
                "subscription": [{"amount": 5000000, "unit": "msats", "period": 2592000}],
                "publication": [{"kinds": [4], "amount": 100, "unit": "msats"}]
              }
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)
        let fees = try #require(info.fees)

        #expect(fees.admission?.first?.amount == 1_000_000)
        #expect(fees.admission?.first?.unit == "msats")
        #expect(fees.subscription?.first?.period == .seconds(2_592_000))
        #expect(fees.publication?.first?.kinds == [4])
        #expect(fees.publication?.first?.amount == 100)
    }

    @Test("Decode retention with mixed kinds (single and range)")
    func decodeRetentionMixedKinds() throws {
        let json = Data(
            #"""
            {
              "retention": [
                {"kinds": [0, 1, [5, 7], [40, 49]], "time": 3600},
                {"kinds": [[30000, 39999]], "time": 100},
                {"time": 3600},
                {"kinds": [4], "count": 1000}
              ]
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)
        let retention = try #require(info.retention)

        #expect(retention.count == 4)

        // First entry: mixed single and range kinds
        let first = retention[0]
        #expect(first.kinds?.count == 4)
        #expect(first.kinds?[0] == .single(0))
        #expect(first.kinds?[1] == .single(1))
        #expect(first.kinds?[2] == .range(5, 7))
        #expect(first.kinds?[3] == .range(40, 49))
        #expect(first.time == .seconds(3600))
        #expect(first.count == nil)

        // Second entry: single range
        #expect(retention[1].kinds?[0] == .range(30000, 39999))

        // Third entry: no kinds (applies to all)
        #expect(retention[2].kinds == nil)
        #expect(retention[2].time == .seconds(3600))

        // Fourth entry: single kind with count
        #expect(retention[3].kinds?[0] == .single(4))
        #expect(retention[3].count == 1000)
    }

    @Test("retention time keeps 0 as zero and an absent time as no limit")
    func retentionTimeSemantics() throws {
        let json = Data(#"{"retention":[{"kinds":[4],"time":0},{"kinds":[1]}]}"#.utf8)
        let retention = try #require(try JSONDecoder().decode(RelayInformation.self, from: json).retention)

        #expect(retention[0].time == .zero)
        #expect(retention[1].time == nil)
    }

    @Test("retention time and fee period round-trip as integer seconds")
    func periodsRoundTripAsSeconds() throws {
        let original = RelayInformation(
            fees: RelayInformation.Fees(
                subscription: [RelayInformation.FeeSchedule(amount: 5000, unit: "msats", period: .seconds(2_592_000))]
            ),
            retention: [
                RelayInformation.Retention(kinds: [.single(4)], time: .zero),
                RelayInformation.Retention(time: .milliseconds(3_600_900)),
                RelayInformation.Retention(count: 10),
            ]
        )

        let data = try JSONEncoder().encode(original)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let fees = try #require(object["fees"] as? [String: Any])
        let subscription = try #require((fees["subscription"] as? [[String: Any]])?.first)
        #expect(subscription["period"] as? Int == 2_592_000)
        let retention = try #require(object["retention"] as? [[String: Any]])
        #expect(retention[0]["time"] as? Int == 0)
        #expect(retention[1]["time"] as? Int == 3600)
        #expect(retention[2]["time"] == nil)

        let decoded = try JSONDecoder().decode(RelayInformation.self, from: data)
        #expect(decoded.fees?.subscription?.first?.period == .seconds(2_592_000))
        #expect(decoded.retention?.map(\.time) == [.zero, .seconds(3600), nil])
    }

    @Test("a non-integer retention time or fee period fails decoding")
    func nonIntegerPeriodsFail() {
        let documents = [
            #"{"retention":[{"time":1.5}]}"#,
            #"{"fees":{"subscription":[{"period":"30"}]}}"#,
        ]
        for document in documents {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(RelayInformation.self, from: Data(document.utf8))
            }
        }
    }

    @Test("Decode full NIP-11 example document")
    func decodeFullDocument() throws {
        let json = Data(
            #"""
            {
              "name": "Full Example Relay",
              "description": "A fully-featured example relay",
              "banner": "https://example.com/banner.png",
              "icon": "https://example.com/icon.png",
              "pubkey": "0000000000000000000000000000000000000000000000000000000000000001",
              "contact": "admin@example.com",
              "supported_nips": [1, 2, 9, 11, 17, 42],
              "software": "git+https://github.com/example/relay",
              "version": "0.1.0",
              "limitation": {
                "max_message_length": 16384,
                "auth_required": false,
                "payment_required": false
              },
              "relay_countries": ["*"],
              "language_tags": ["en"],
              "tags": ["general"],
              "posting_policy": "https://example.com/policy",
              "payments_url": "https://example.com/pay",
              "fees": {
                "admission": [{"amount": 1000, "unit": "msats"}]
              },
              "retention": [
                {"kinds": [0, 3], "count": 1}
              ]
            }
            """#.utf8)

        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.name == "Full Example Relay")
        #expect(info.supportedNIPs?.contains(11) == true)
        #expect(info.limitation?.maximumMessageLength == 16384)
        #expect(info.fees?.admission?.first?.amount == 1000)
        #expect(info.retention?.first?.kinds?[0] == .single(0))
        #expect(info.retention?.first?.count == 1)
    }

    @Test("Unknown fields are ignored")
    func unknownFieldsIgnored() throws {
        let json = Data(#"{"name":"x","experimental_future_field":{"nested":42}}"#.utf8)
        let info = try JSONDecoder().decode(RelayInformation.self, from: json)

        #expect(info.name == "x")
    }

    // MARK: - JSON Encoding Tests

    @Test("Encoding omits nil fields")
    func encodingOmitsNilFields() throws {
        let info = RelayInformation(name: "example")
        let data = try JSONEncoder().encode(info)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"name\":\"example\""))
        #expect(!json.contains("description"))
        #expect(!json.contains("null"))
    }

    @Test("Encoding uses snake_case keys")
    func encodingUsesSnakeCaseKeys() throws {
        let info = RelayInformation(
            selfPublicKey: PublicKey.fixture("abc"),
            supportedNIPs: [1],
            termsOfService: "https://example.com/tos",
            relayCountries: ["US"],
            languageTags: ["en"],
            postingPolicy: "https://example.com/policy",
            paymentsURL: "https://example.com/pay"
        )
        let data = try JSONEncoder().encode(info)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("\"self\":"))
        #expect(json.contains("\"supported_nips\":"))
        #expect(json.contains("\"terms_of_service\":"))
        #expect(json.contains("\"relay_countries\":"))
        #expect(json.contains("\"language_tags\":"))
        #expect(json.contains("\"posting_policy\":"))
        #expect(json.contains("\"payments_url\":"))
    }

    @Test("KindSpec round-trip preserves format")
    func kindSpecRoundTrip() throws {
        let retention = RelayInformation.Retention(
            kinds: [.single(0), .single(1), .range(5, 7), .range(30000, 39999)],
            time: .seconds(3600)
        )
        let info = RelayInformation(retention: [retention])

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(RelayInformation.self, from: data)

        #expect(decoded.retention?.first?.kinds == retention.kinds)

        // Verify single values encode as integers, not arrays
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("[0,1,[5,7],[30000,39999]]"))
    }

    @Test("Full round-trip preserves document")
    func fullRoundTrip() throws {
        let original = RelayInformation(
            name: "Test",
            supportedNIPs: [1, 11],
            limitation: RelayInformation.Limitation(
                maximumMessageLength: 16384,
                authRequired: true
            ),
            fees: RelayInformation.Fees(
                admission: [RelayInformation.FeeSchedule(amount: 100, unit: "msats")]
            ),
            retention: [RelayInformation.Retention(kinds: [.range(1000, 1999)], time: .zero)]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RelayInformation.self, from: data)

        #expect(decoded == original)
    }

    // MARK: - KindSpec Tests

    @Test("KindSpec rejects invalid array length")
    func kindSpecRejectsInvalidArrayLength() {
        let json = Data("[[1, 2, 3]]".utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([RelayInformation.KindSpec].self, from: json)
        }
    }

    @Test("KindSpec rejects non-integer values")
    func kindSpecRejectsNonIntegerValues() {
        let json = Data(#"["abc"]"#.utf8)

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode([RelayInformation.KindSpec].self, from: json)
        }
    }

    // MARK: - Fetch Error Tests

    @Test("FetchError descriptions are non-nil")
    func fetchErrorDescriptions() {
        #expect(RelayInformation.FetchError.networkError("x").errorDescription != nil)
        #expect(RelayInformation.FetchError.invalidResponse.errorDescription != nil)
        #expect(RelayInformation.FetchError.decodingFailed("x").errorDescription != nil)
    }

    // MARK: - Sendable/Hashable/Equatable

    @Test("RelayInformation is Hashable")
    func relayInformationIsHashable() {
        let info1 = RelayInformation(name: "x", supportedNIPs: [1])
        let info2 = RelayInformation(name: "x", supportedNIPs: [1])
        let info3 = RelayInformation(name: "y", supportedNIPs: [1])

        var set: Set<RelayInformation> = []
        set.insert(info1)
        set.insert(info2)
        set.insert(info3)

        #expect(set.count == 2)
    }

    @Test("RelayInformation equality")
    func relayInformationEquality() {
        let info1 = RelayInformation(name: "x", supportedNIPs: [1, 2])
        let info2 = RelayInformation(name: "x", supportedNIPs: [1, 2])
        let info3 = RelayInformation(name: "x", supportedNIPs: [1, 3])

        #expect(info1 == info2)
        #expect(info1 != info3)
    }

    // MARK: - HTTP Fetch Tests (URLProtocol mock)

    @Test("Fetch sends GET to converted https URL with nostr+json Accept header")
    func fetchSendsCorrectRequest() async throws {
        let relayURL = RelayURL("wss://relay.example.com/ws?token=abc")!
        let body = Data(#"{"name":"mocked"}"#.utf8)

        let captured = try await withMockURLSession(
            response: .success(status: 200, body: body)
        ) { session in
            _ = try await RelayInformation.fetch(from: relayURL, urlSession: session)
        }

        let request = try #require(captured.request)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://relay.example.com/ws?token=abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/nostr+json")
    }

    @Test("Fetch decodes successful 200 response")
    func fetchDecodesSuccessfulResponse() async throws {
        let body = Data(
            #"""
            {"name":"Mock Relay","supported_nips":[1,11],"limitation":{"auth_required":true}}
            """#.utf8)

        let info: RelayInformation = try await withMockURLSession(
            response: .success(status: 200, body: body)
        ) { session in
            try await RelayInformation.fetch(
                from: RelayURL("wss://relay.example.com")!,
                urlSession: session
            )
        }.returnValue

        #expect(info.name == "Mock Relay")
        #expect(info.supportedNIPs == [1, 11])
        #expect(info.limitation?.authRequired == true)
    }

    @Test("Fetch throws invalidResponse on non-2xx status")
    func fetchThrowsInvalidResponseOnNon2xx() async {
        for status in [400, 404, 500, 503] {
            do {
                _ = try await withMockURLSession(
                    response: .success(status: status, body: Data("{}".utf8))
                ) { session in
                    try await RelayInformation.fetch(
                        from: RelayURL("wss://relay.example.com")!,
                        urlSession: session
                    )
                }.returnValue
                Issue.record("Expected error for status \(status)")
            } catch let error as RelayInformation.FetchError {
                if case .invalidResponse = error {
                    // Expected
                } else {
                    Issue.record("Unexpected FetchError for status \(status): \(error)")
                }
            } catch {
                Issue.record("Unexpected error type for status \(status): \(error)")
            }
        }
    }

    @Test("Fetch throws decodingFailed on invalid JSON")
    func fetchThrowsDecodingFailedOnInvalidJSON() async {
        do {
            _ = try await withMockURLSession(
                response: .success(status: 200, body: Data("not json at all".utf8))
            ) { session in
                try await RelayInformation.fetch(
                    from: RelayURL("wss://relay.example.com")!,
                    urlSession: session
                )
            }.returnValue
            Issue.record("Expected error to be thrown")
        } catch let error as RelayInformation.FetchError {
            if case .decodingFailed = error {
                // Expected
            } else {
                Issue.record("Unexpected FetchError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Fetch throws decodingFailed when JSON has wrong field types")
    func fetchThrowsDecodingFailedOnTypeMismatch() async {
        // supported_nips should be [Int] — give it [String] instead
        let body = Data(#"{"supported_nips":["one","two"]}"#.utf8)
        do {
            _ = try await withMockURLSession(
                response: .success(status: 200, body: body)
            ) { session in
                try await RelayInformation.fetch(
                    from: RelayURL("wss://relay.example.com")!,
                    urlSession: session
                )
            }.returnValue
            Issue.record("Expected error to be thrown")
        } catch let error as RelayInformation.FetchError {
            if case .decodingFailed = error {
                // Expected
            } else {
                Issue.record("Unexpected FetchError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Fetch maps URLSession errors to networkError")
    func fetchMapsURLErrorsToNetworkError() async {
        do {
            _ = try await withMockURLSession(
                response: .failure(URLError(.cannotConnectToHost))
            ) { session in
                try await RelayInformation.fetch(
                    from: RelayURL("wss://relay.example.com")!,
                    urlSession: session
                )
            }.returnValue
            Issue.record("Expected error to be thrown")
        } catch let error as RelayInformation.FetchError {
            if case .networkError = error {
                // Expected
            } else {
                Issue.record("Unexpected FetchError: \(error)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Fetch remaps URLError(.cancelled) to CancellationError")
    func fetchPropagatesCancellation() async {
        // URLSession surfaces task cancellation as URLError(.cancelled); we
        // remap it to CancellationError so callers can use standard Swift
        // Concurrency cancellation handling instead of receiving it disguised
        // as a generic network error.
        do {
            _ = try await withMockURLSession(
                response: .failure(URLError(.cancelled))
            ) { session in
                try await RelayInformation.fetch(
                    from: RelayURL("wss://relay.example.com")!,
                    urlSession: session
                )
            }.returnValue
            Issue.record("Expected error to be thrown")
        } catch is CancellationError {
            // Expected — URLError(.cancelled) is remapped to CancellationError
        } catch {
            Issue.record("Unexpected error type: \(error) (expected CancellationError)")
        }
    }
}
