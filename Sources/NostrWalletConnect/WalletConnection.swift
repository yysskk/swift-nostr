import Foundation
public import NostrCore

/// A connection to a remote Lightning wallet over NIP-47 Nostr Wallet Connect.
///
/// Build one from a ``WalletConnectURI`` and call the typed commands (see
/// `WalletConnection+Commands`). Each command encrypts a request, signs a kind-23194 event with the
/// URI's secret key, sends it to the wallet's relay, and awaits the matching kind-23195 response,
/// correlated by the response's `e` tag.
///
/// ### Encryption
/// By default the connection encrypts with NIP-44 (which NIP-47 says clients should prefer). To talk
/// to a legacy NIP-04-only wallet, either set ``Config/preferredEncryption`` to `.nip04`, or call
/// ``fetchInfo()`` first — it caches the wallet's advertised capabilities and the connection then
/// uses the negotiated scheme.
///
/// https://github.com/nostr-protocol/nips/blob/master/47.md
public actor WalletConnection {
    /// Connection behavior.
    public struct Config: Sendable {
        /// How long to wait for a response before failing a request. Default: 30 seconds.
        public var requestTimeout: TimeInterval

        /// Forces an encryption scheme instead of negotiating. Default: `nil` (prefer NIP-44, or the
        /// scheme negotiated by ``WalletConnection/fetchInfo()``).
        public var preferredEncryption: WalletConnectEncryption?

        public init(requestTimeout: TimeInterval = 30, preferredEncryption: WalletConnectEncryption? = nil) {
            self.requestTimeout = requestTimeout
            self.preferredEncryption = preferredEncryption
        }
    }

    private static let responseSubscriptionID = "nwc-responses"
    private static let infoSubscriptionID = "nwc-info"

    /// The shared relay session, correlating each request by its event id (which responses echo in
    /// their `e` tag) and holding the parts collected for it so far.
    private typealias Session = RequestResponseSession<String, RequestState, [ResponsePart]>

    private let session: Session
    private let config: Config
    private let keyPair: KeyPair
    private let signer: EventSigner
    private let walletPubkey: String
    private let clientPubkey: String

    /// Open notification streams, keyed so each can deregister on termination.
    private var notificationStreams: [UUID: AsyncStream<WalletConnectNotification>.Continuation] = [:]
    /// The current ``fetchInfo()`` waiter, if any.
    private var pendingInfo: AsyncThrowingStream<WalletInfo, any Error>.Continuation?

    /// The last fetched wallet info, if any.
    public private(set) var info: WalletInfo?

    /// Creates a connection.
    /// - Parameters:
    ///   - uri: The wallet's connection URI.
    ///   - transport: The relay transport. Defaults to a `RelayConnectionTransport` over the URI's
    ///     relays; inject a custom one (e.g. for tests).
    ///   - config: Connection behavior.
    public init(uri: WalletConnectURI, transport: (any RelayTransport)? = nil, config: Config = Config()) {
        let keyPair = uri.clientKeyPair()
        self.config = config
        self.keyPair = keyPair
        self.signer = EventSigner(keyPair: keyPair)
        self.walletPubkey = uri.walletPubkey
        self.clientPubkey = keyPair.publicKeyHex
        self.session = Session(
            transport: transport ?? RelayConnectionTransport(relayURLs: uri.relays),
            timedOut: WalletConnectError.timedOut,
            notConnected: WalletConnectError.notConnected)
    }

    // MARK: - Lifecycle

    /// Connects to the relay and starts listening for responses and notifications. Commands call
    /// this automatically; call it explicitly to surface connection errors up front.
    public func connect() async throws {
        try await ensureStarted()
    }

    /// Disconnects, failing any in-flight requests and ending the notification streams.
    public func disconnect() async {
        pendingInfo?.finish(throwing: WalletConnectError.notConnected)
        pendingInfo = nil

        for stream in notificationStreams.values {
            stream.finish()
        }
        notificationStreams.removeAll()

        await session.disconnect()
    }

    /// Connects, subscribes for responses and notifications, and starts reading them — once per
    /// connection.
    private func ensureStarted() async throws {
        try await session.ensureStarted(
            subscriptionID: Self.responseSubscriptionID,
            filters: [responseFilter]
        ) { [weak self] event in
            await self?.handle(event)
        }
    }

    // MARK: - Info

    /// Fetches the wallet's NIP-47 info event (kind 13194) and caches it, so later commands use the
    /// negotiated encryption scheme.
    /// - Returns: The parsed ``WalletInfo``.
    /// - Throws: ``WalletConnectError/timedOut`` if no info event arrives within the request timeout.
    @discardableResult
    public func fetchInfo() async throws -> WalletInfo {
        try await ensureStarted()

        // Register the waiter before subscribing so an info event delivered during the subscribe
        // round-trip is buffered into this stream rather than dropped.
        let (stream, continuation) = AsyncThrowingStream<WalletInfo, any Error>.makeStream()
        // A prior in-flight fetchInfo is superseded by this one (the connection stays active).
        pendingInfo?.finish(throwing: WalletConnectError.superseded)
        pendingInfo = continuation

        try await session.subscribe(id: Self.infoSubscriptionID, filters: [infoFilter])
        defer {
            Task { [weak self, session] in
                // If a concurrent fetchInfo() superseded this one and is still waiting, it owns the
                // subscription — don't close it out from under the survivor.
                if await self?.isFetchingInfo == true { return }
                await session.unsubscribe(id: Self.infoSubscriptionID)
            }
        }

        let timeout = config.requestTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            // If this call was superseded/finished, its timeout was cancelled — don't end the
            // continuation that now belongs to a concurrent fetchInfo().
            guard !Task.isCancelled else { return }
            await self?.failPendingInfo()
        }
        defer { timeoutTask.cancel() }

        for try await walletInfo in stream {
            return walletInfo
        }
        throw WalletConnectError.timedOut
    }

    private func failPendingInfo() {
        pendingInfo?.finish(throwing: WalletConnectError.timedOut)
        pendingInfo = nil
    }

    /// Whether a ``fetchInfo()`` call is currently waiting on the info subscription.
    private var isFetchingInfo: Bool {
        pendingInfo != nil
    }

    // MARK: - Notifications

    /// A stream of wallet notifications (kinds 23196 / 23197), decrypted and parsed.
    ///
    /// Starts the connection if it isn't already, so a caller can subscribe to notifications without
    /// first issuing a command or calling ``connect()``.
    public func notifications() async throws -> AsyncStream<WalletConnectNotification> {
        try await ensureStarted()
        let id = UUID()
        let (stream, continuation) = AsyncStream<WalletConnectNotification>.makeStream()
        notificationStreams[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeNotificationStream(id) }
        }
        return stream
    }

    private func removeNotificationStream(_ id: UUID) {
        notificationStreams[id] = nil
    }

    // MARK: - Requests

    /// Sends a request and collects its response(s), correlated by the request event's id.
    /// - Parameters:
    ///   - method: The command method.
    ///   - params: The command parameters.
    ///   - expectedResponses: How many response events to collect before completing (one for most
    ///     commands; the item count for `multi_pay_*`).
    ///   - partialOnTimeout: When true, a timeout returns whatever responses arrived instead of
    ///     throwing (used by `multi_pay_*`).
    /// - Returns: The collected, decrypted response parts.
    func performRequest(
        method: WalletConnectMethod,
        params: some Encodable,
        expectedResponses: Int = 1,
        partialOnTimeout: Bool = false
    ) async throws -> [ResponsePart] {
        try await ensureStarted()

        let scheme = activeEncryption
        let event = try buildRequestEvent(method: method, params: params, scheme: scheme)
        // A timed-out multi_pay_* resolves with the responses that did arrive rather than failing.
        let collected: Session.PartialResult = { $0.collected }
        return try await session.perform(
            event,
            key: event.id,
            state: RequestState(scheme: scheme, expected: expectedResponses, method: method),
            timeout: config.requestTimeout,
            partialResult: partialOnTimeout ? collected : nil)
    }

    /// Sends a request expecting exactly one response and returns its decrypted content.
    func performSingle(method: WalletConnectMethod, params: some Encodable) async throws -> String {
        let parts = try await performRequest(method: method, params: params)
        guard let first = parts.first else { throw WalletConnectError.timedOut }
        return first.content
    }

    /// Decodes a decrypted response content string into `Result`, mapping a wallet `error` object to
    /// ``WalletConnectError/walletError(code:message:)``.
    func decodeResult<Result: Decodable>(_ content: String, as _: Result.Type) throws -> Result {
        let response: WalletConnectResponse<Result>
        do {
            response = try JSONDecoder().decode(WalletConnectResponse<Result>.self, from: Data(content.utf8))
        } catch {
            throw WalletConnectError.responseDecodingFailed
        }
        if let error = response.error {
            throw WalletConnectError.walletError(
                code: WalletConnectErrorCode(rawValue: error.code), message: error.message)
        }
        guard let result = response.result else {
            throw WalletConnectError.missingResult
        }
        return result
    }

    private var activeEncryption: WalletConnectEncryption {
        config.preferredEncryption ?? info?.negotiatedEncryption ?? .nip44
    }

    private func buildRequestEvent(
        method: WalletConnectMethod, params: some Encodable, scheme: WalletConnectEncryption
    ) throws -> Event {
        let request = WalletConnectRequest(method: method, params: params)
        let content: String
        do {
            let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
            content = try WalletConnectCipher(scheme).encrypt(json, recipientPubkey: walletPubkey, sender: keyPair)
        } catch {
            throw WalletConnectError.requestEncodingFailed
        }

        let expiration = Int64(Date().timeIntervalSince1970) + Int64(config.requestTimeout) + 10
        let tags: [[String]] = [
            ["p", walletPubkey],
            ["encryption", scheme.rawValue],
            ["expiration", String(expiration)],
        ]
        let unsigned = UnsignedEvent(
            pubkey: clientPubkey, kind: .walletConnectRequest, rawTags: tags, content: content)
        do {
            return try signer.sign(unsigned)
        } catch {
            throw WalletConnectError.requestEncodingFailed
        }
    }

    // MARK: - Incoming events

    private func handle(_ event: Event) async {
        // The relay filter already restricts authors, but enforce it here too as defense in depth —
        // and require the event to say what it was signed to say, so nothing downstream reads a
        // payload whose author has not actually vouched for it.
        guard event.pubkey == walletPubkey, (try? event.verify()) == true else { return }
        switch event.kind {
        case .walletConnectResponse:
            await handleResponse(event)
        case .walletConnectNotification:
            handleNotification(event, scheme: .nip44)
        case .walletConnectNotificationLegacy:
            handleNotification(event, scheme: .nip04)
        case .walletConnectInfo:
            handleInfo(event)
        default:
            break
        }
    }

    private func handleResponse(_ event: Event) async {
        guard let requestID = event.firstTagValue(named: "e") else { return }
        let walletPubkey = walletPubkey
        let keyPair = keyPair

        // The response names the scheme it was encrypted with; the request's own scheme is only a
        // fallback for a wallet that sends no tag. Assuming the request's scheme meant a NIP-04
        // wallet's reply — including the `UNSUPPORTED_ENCRYPTION` error explaining the mismatch —
        // failed to decrypt and surfaced as a generic decoding failure, with nothing pointing at
        // the cause.
        let declaredScheme = event.firstTagValue(named: "encryption")
        let responseScheme = declaredScheme.map { WalletConnectEncryption(rawValue: $0) }

        await session.withPendingRequest(requestID) { request in
            // A connection URI may list several relays, and the transport merges them without
            // deduplicating — that only happens in `RelayPool`, which this path does not use. One
            // response arriving over two relays would otherwise count twice, completing a
            // `multi_pay_*` early with a duplicate part while the response it was still owed had
            // nowhere left to go.
            guard request.seenResponseIDs.insert(event.id).inserted else { return .pending }
            request.receivedCount += 1

            // A tag naming a scheme this package does not implement is reported as such: the
            // payload cannot be read, and saying so beats a decoding failure that suggests the
            // wallet sent something malformed.
            guard let scheme = responseScheme ?? request.scheme else {
                if request.expected == 1 {
                    return .failed(
                        WalletConnectError.unsupportedEncryption(declaredScheme ?? ""))
                }
                return request.receivedCount >= request.expected ? .resolved(request.collected) : .pending
            }

            guard
                let content = try? WalletConnectCipher(scheme).decrypt(
                    event.content, senderPubkey: walletPubkey, recipient: keyPair)
            else {
                // Nothing to preserve for a single-response request, so fail fast.
                if request.expected == 1 {
                    return .failed(WalletConnectError.responseDecodingFailed)
                }
                // Count undecryptable responses toward completion so a multi-response request
                // finishes as soon as every response has arrived, rather than waiting out the
                // timeout.
                return request.receivedCount >= request.expected ? .resolved(request.collected) : .pending
            }

            // A reply naming another command answers a different request; folding it in would let
            // a body of the wrong shape satisfy this one whenever it happened to decode.
            if let received = Self.resultType(of: content), received != request.method.rawValue {
                if request.expected == 1 {
                    return .failed(
                        WalletConnectError.unexpectedResultType(
                            expected: request.method.rawValue, received: received))
                }
                return request.receivedCount >= request.expected ? .resolved(request.collected) : .pending
            }

            request.collected.append(ResponsePart(dTag: event.firstTagValue(named: "d"), content: content))
            return request.receivedCount >= request.expected ? .resolved(request.collected) : .pending
        }
    }

    /// The `result_type` a decrypted response declares, or nil when it does not parse as one.
    ///
    /// A reply naming another command is an answer to a different request; folding it in would let
    /// a `get_balance` body satisfy a `pay_invoice` whenever the shapes happened to decode. An
    /// unparseable body keeps its old path — it is reported as a decoding failure downstream, which
    /// says more than silently discarding it here would.
    private static func resultType(of content: String) -> String? {
        struct ResultTypeOnly: Decodable {
            let resultType: String

            enum CodingKeys: String, CodingKey {
                case resultType = "result_type"
            }
        }
        return try? JSONDecoder().decode(ResultTypeOnly.self, from: Data(content.utf8)).resultType
    }

    private func handleNotification(_ event: Event, scheme: WalletConnectEncryption) {
        guard !notificationStreams.isEmpty,
            let content = try? WalletConnectCipher(scheme).decrypt(
                event.content, senderPubkey: walletPubkey, recipient: keyPair),
            let notification = WalletConnectNotification(content: content)
        else {
            return
        }
        for stream in notificationStreams.values {
            stream.yield(notification)
        }
    }

    private func handleInfo(_ event: Event) {
        guard let walletInfo = WalletInfo(infoEvent: event) else { return }
        info = walletInfo
        pendingInfo?.yield(walletInfo)
        pendingInfo?.finish()
        pendingInfo = nil
    }

    // MARK: - Filters

    private var responseFilter: Filter {
        Filter(
            authors: [walletPubkey],
            kinds: [.walletConnectResponse, .walletConnectNotification, .walletConnectNotificationLegacy],
            pubkeyReferences: [clientPubkey])
    }

    private var infoFilter: Filter {
        Filter(authors: [walletPubkey], kinds: [.walletConnectInfo], limit: 1)
    }
}

/// One decrypted response event: its `d` tag (used to correlate `multi_pay_*` items) and content.
struct ResponsePart: Sendable {
    let dTag: String?
    let content: String
}

/// What an in-flight request needs from its own responses: the scheme they are encrypted with, how
/// many to expect, and the ones that have arrived.
private struct RequestState: Sendable {
    let scheme: WalletConnectEncryption
    let expected: Int
    /// The method the request was sent under, so a reply carrying another `result_type` — an answer
    /// to a different command — is not folded in as though it belonged here.
    let method: WalletConnectMethod
    /// The successfully decrypted response parts.
    var collected: [ResponsePart] = []
    /// Total responses seen (including undecryptable ones), used for the completion check.
    var receivedCount = 0
    /// Response event ids already folded in, so a response delivered over more than one relay is
    /// counted once.
    var seenResponseIDs: Set<String> = []
}
