import Foundation
import NostrClient
import NostrCore

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

    private let transport: any WalletConnectTransport
    private let config: Config
    private let keyPair: KeyPair
    private let signer: EventSigner
    private let walletPubkey: String
    private let clientPubkey: String

    private var isStarted = false
    private var readerTask: Task<Void, Never>?

    /// In-flight requests keyed by request event id (responses reference it in their `e` tag).
    private var pending: [String: PendingRequest] = [:]
    /// Open notification streams, keyed so each can deregister on termination.
    private var notificationStreams: [UUID: AsyncStream<WalletConnectNotification>.Continuation] = [:]
    /// The current ``fetchInfo()`` waiter, if any.
    private var pendingInfo: AsyncThrowingStream<WalletInfo, Error>.Continuation?

    /// The last fetched wallet info, if any.
    public private(set) var info: WalletInfo?

    /// Creates a connection.
    /// - Parameters:
    ///   - uri: The wallet's connection URI.
    ///   - transport: The relay transport. Defaults to a ``RelayConnectionTransport`` over the URI's
    ///     relays; inject a custom one (e.g. for tests).
    ///   - config: Connection behavior.
    public init(uri: WalletConnectURI, transport: (any WalletConnectTransport)? = nil, config: Config = Config()) {
        let keyPair = uri.clientKeyPair()
        self.config = config
        self.keyPair = keyPair
        self.signer = EventSigner(keyPair: keyPair)
        self.walletPubkey = uri.walletPubkey
        self.clientPubkey = keyPair.publicKeyHex
        self.transport = transport ?? RelayConnectionTransport(relayURLs: uri.relays)
    }

    // MARK: - Lifecycle

    /// Connects to the relay and starts listening for responses and notifications. Commands call
    /// this automatically; call it explicitly to surface connection errors up front.
    public func connect() async throws {
        try await ensureStarted()
    }

    /// Disconnects, failing any in-flight requests and ending the notification streams.
    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        isStarted = false

        for request in pending.values {
            request.continuation.finish(throwing: WalletConnectError.notConnected)
        }
        pending.removeAll()

        pendingInfo?.finish(throwing: WalletConnectError.notConnected)
        pendingInfo = nil

        for stream in notificationStreams.values {
            stream.finish()
        }
        notificationStreams.removeAll()

        await transport.disconnect()
    }

    private func ensureStarted() async throws {
        guard !isStarted else { return }
        // Set before the first await so a concurrent caller can't race through this setup a second
        // time (actor reentrancy). Reset on failure so a later attempt can retry.
        isStarted = true
        do {
            try await transport.connect()
            try await transport.subscribe(id: Self.responseSubscriptionID, filters: [responseFilter])
            let events = await transport.events()
            readerTask = Task { [weak self] in
                for await event in events {
                    await self?.handle(event)
                }
            }
        } catch {
            isStarted = false
            throw error
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
        let (stream, continuation) = AsyncThrowingStream<WalletInfo, Error>.makeStream()
        // A prior in-flight fetchInfo is superseded by this one (the connection stays active).
        pendingInfo?.finish(throwing: WalletConnectError.superseded)
        pendingInfo = continuation

        try await transport.subscribe(id: Self.infoSubscriptionID, filters: [infoFilter])
        defer {
            Task { [weak self, transport] in
                // If a concurrent fetchInfo() superseded this one and is still waiting, it owns the
                // subscription — don't close it out from under the survivor.
                if await self?.isFetchingInfo == true { return }
                await transport.unsubscribe(id: Self.infoSubscriptionID)
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
        let requestID = event.id

        let (stream, continuation) = AsyncThrowingStream<[ResponsePart], Error>.makeStream()
        pending[requestID] = PendingRequest(
            scheme: scheme, collected: [], receivedCount: 0, expected: expectedResponses, continuation: continuation)

        let timeout = config.requestTimeout
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.timeoutRequest(requestID, partial: partialOnTimeout)
        }
        defer {
            timeoutTask.cancel()
            pending.removeValue(forKey: requestID)
        }

        try await transport.send(event)

        for try await parts in stream {
            return parts
        }
        throw WalletConnectError.timedOut
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

    private func timeoutRequest(_ requestID: String, partial: Bool) {
        guard let request = pending.removeValue(forKey: requestID) else { return }
        if partial {
            request.continuation.yield(request.collected)
            request.continuation.finish()
        } else {
            request.continuation.finish(throwing: WalletConnectError.timedOut)
        }
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

    private func handle(_ event: Event) {
        // The relay filter already restricts authors, but enforce it here too as defense in depth.
        guard event.pubkey == walletPubkey else { return }
        switch event.kind {
        case .walletConnectResponse:
            handleResponse(event)
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

    private func handleResponse(_ event: Event) {
        guard let requestID = event.firstTagValue(named: "e"), var request = pending[requestID] else { return }
        request.receivedCount += 1

        if let content = try? WalletConnectCipher(request.scheme).decrypt(
            event.content, senderPubkey: walletPubkey, recipient: keyPair)
        {
            request.collected.append(ResponsePart(dTag: event.firstTagValue(named: "d"), content: content))
        } else if request.expected == 1 {
            // Nothing to preserve for a single-response request, so fail fast.
            pending.removeValue(forKey: requestID)
            request.continuation.finish(throwing: WalletConnectError.responseDecodingFailed)
            return
        }

        // Count undecryptable responses toward completion so a multi-response request finishes as
        // soon as every response has arrived, rather than waiting out the timeout.
        if request.receivedCount >= request.expected {
            pending.removeValue(forKey: requestID)
            request.continuation.yield(request.collected)
            request.continuation.finish()
        } else {
            pending[requestID] = request
        }
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

/// State for an in-flight request awaiting one or more responses.
private struct PendingRequest {
    let scheme: WalletConnectEncryption
    /// The successfully decrypted response parts.
    var collected: [ResponsePart]
    /// Total responses seen (including undecryptable ones), used for the completion check.
    var receivedCount: Int
    let expected: Int
    let continuation: AsyncThrowingStream<[ResponsePart], Error>.Continuation
}
