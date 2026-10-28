# Advanced Usage

Encryption negotiation, the full command set, sending other commands, notifications, custom
transports, and error handling.

## Connection Configuration

``WalletConnection/Config`` tunes how a connection behaves. Pass it to the initializer:

```swift
let config = WalletConnection.Config(
    requestTimeout: .seconds(30),   // wait for a response before failing
    preferredEncryption: nil)       // nil negotiates; set to force a scheme
let connection = WalletConnection(uri: uri, config: config)
```

Commands connect lazily on first use. Call ``WalletConnection/connect()`` to surface connection
errors up front, and ``WalletConnection/disconnect()`` to tear down the relay connection, fail any
in-flight requests with ``WalletConnectError/notConnected``, and end the notification streams.

## Encryption Negotiation (NIP-44 / NIP-04)

NIP-47 payloads are encrypted, and a wallet may speak NIP-44 (preferred) or legacy NIP-04. By
default a connection encrypts with ``WalletConnectEncryption/nip44``. There are two ways to talk to
a NIP-04-only wallet:

```swift
// 1. Force a scheme explicitly.
let config = WalletConnection.Config(preferredEncryption: .nip04)
let connection = WalletConnection(uri: uri, config: config)

// 2. Negotiate from the wallet's advertised capabilities.
let capabilities = try await connection.fetchCapabilities() // cached; later commands negotiate
print(capabilities.negotiatedEncryption)                    // .nip44 when supported, else .nip04
```

``WalletConnection/fetchCapabilities()`` fetches the wallet's info event (kind 13194) and caches
the capabilities it advertises, so subsequent commands automatically use
``WalletCapabilities/negotiatedEncryption``. An explicit
``WalletConnection/Config/preferredEncryption`` always wins over negotiation.

## Inspecting Wallet Capabilities

``WalletCapabilities`` describes what a wallet supports. Use it to gate features before issuing a
command that the wallet would reject:

```swift
let capabilities = try await connection.fetchCapabilities()

if capabilities.supports(.payInvoice) {
    let payment = try await connection.payInvoice("lnbc...")
    print(payment.preimage)
}

print("Methods:", capabilities.methods)             // every advertised command
print("Encryptions:", capabilities.encryptions)     // never empty; defaults to [.nip04]
print("Notifications:", capabilities.notifications) // e.g. [payment_received, payment_sent]
```

``WalletConnectMethod`` is open-ended: ``WalletCapabilities/methods`` keeps every token the wallet
advertises, and a method this package has no constant for is checked with
``WalletConnectMethod/init(rawValue:)``:

```swift
if capabilities.supports(WalletConnectMethod(rawValue: "sign_message")) {
    // the wallet advertises a command outside the built-in set
}
```

## Invoices and Balance

```swift
// Create an invoice to receive a payment.
let created = try await connection.makeInvoice(amount: 21_000, description: "coffee", expiry: .seconds(3600))
print(created.invoice ?? "")   // a WalletConnectTransaction

// Look up an invoice — by payment hash or by BOLT-11 string. The key is exactly one of the two.
let byHash = try await connection.lookupInvoice(.paymentHash("abc123..."))
let byBolt11 = try await connection.lookupInvoice(.invoice("lnbc..."))
print(byHash.state == .settled, byBolt11.amount)

// Balance, in millisatoshis.
let balance = try await connection.fetchBalance()
print("\(balance.balance) msat")
```

## Listing Transactions

``WalletConnection/listTransactions(from:until:limit:offset:unpaid:type:)`` returns matching
``WalletConnectTransaction`` values, newest first. Filter by time window (`from` / `until`, each a
`Timestamp`), direction, paid/unpaid, and paginate with `limit` / `offset`. A transaction's `createdAt`, `expiresAt`, and
`settledAt` are `Timestamp` values too:

```swift
let lastWeek = Timestamp.now.advanced(by: .seconds(-7 * 24 * 60 * 60))
let outgoing = try await connection.listTransactions(from: lastWeek, limit: 50, type: .outgoing)
for tx in outgoing {
    print("\(tx.type) \(tx.amount) msat — \(tx.state?.rawValue ?? "?")")
}
```

## Keysend Payments

A keysend is a spontaneous payment to a node's public key, with no invoice. The
`nodePublicKey` is the Lightning node's hex key, not a Nostr `PublicKey`. Attach optional
``TLVRecord`` values for application data:

```swift
let result = try await connection.payKeysend(
    amount: 10_000,
    nodePublicKey: "<lightning-node-public-key-hex>",
    tlvRecords: [TLVRecord(type: 696969, value: "68656c6c6f")])
print(result.preimage)
```

## Multi-Payments

``WalletConnection/multiPayInvoice(_:)`` and ``WalletConnection/multiPayKeysend(_:)`` send several
payments in one request. The wallet replies with one response per item, and the results come back as
``MultiPayResults`` — one outcome per item, in the order you requested them:

```swift
let results = try await connection.multiPayInvoice([
    .init(id: "rent", invoice: "lnbc1..."),
    .init(id: "coffee", invoice: "lnbc2..."),
])
for (index, outcome) in results.outcomes.enumerated() {
    switch outcome {
    case .answered(.success(let payment)): print("\(index): paid, preimage \(payment.preimage)")
    case .answered(.failure(let error)):   print("\(index): \(error.localizedDescription)")
    case .noResponse:                      print("\(index): no response")
    }
}
```

Give every item an `id`. NIP-47 correlates a response by the item's `id` when one was supplied, and
otherwise by the payment hash — which this package cannot derive from an invoice, so a response for
an item sent without an `id` cannot be tied back to it. Anything that cannot be matched, including a
second response under a `d` tag already claimed, is reported in ``MultiPayResults/unmatched`` rather
than dropped: those payments still happened.

Unlike single commands, a multi-payment does not throw on timeout — it returns whatever responses
arrived, so a slow or unreachable item does not lose the payments that already settled. Items that
never got a response are ``MultiPayOutcome/noResponse``, and
``MultiPayResults/indicesWithoutResponse`` lists them.

## Sending Other Commands

Every single-response command is a ``WalletConnectRequest``: a value that encodes as the request's
`params`, with the ``WalletConnectMethod`` it is sent under and the `Response` its `result` decodes
into. The typed commands above send the built-in request types (``PayInvoiceRequest``,
``GetBalanceRequest``, and so on) through ``WalletConnection/send(_:)``, which sends any conforming
value. To call a command this package does not wrap — a wallet extension or a later NIP-47
revision — define the request and response types and send it:

```swift
struct GetBudgetRequest: WalletConnectRequest {
    typealias Response = GetBudgetResult
    static let method = WalletConnectMethod(rawValue: "get_budget")
}

struct GetBudgetResult: Decodable, Sendable {
    let usedBudget: Int64
    let totalBudget: Int64?

    enum CodingKeys: String, CodingKey {
        case usedBudget = "used_budget"
        case totalBudget = "total_budget"
    }
}

let capabilities = try await connection.fetchCapabilities()
if capabilities.supports(GetBudgetRequest.method) {
    let budget = try await connection.send(GetBudgetRequest())
    print("\(budget.usedBudget) msat used")
}
```

``WalletConnection/send(_:)`` behaves like the typed commands: it waits for one response, rejects
one whose `result_type` names another method with
``WalletConnectError/unexpectedResultType(expected:received:)``, and throws a wallet's error as
``WalletConnectError/walletError(code:message:)``. Commands that draw one response per item, like
`multi_pay_invoice`, do not fit this shape and are sent with their dedicated methods.

## Notifications

``WalletConnection/notifications()`` returns an `AsyncStream` of ``WalletConnectNotification`` values
(wallet events of kind 23197 for NIP-44 or 23196 for NIP-04), decrypted and parsed. Standard
`payment_received` / `payment_sent` notifications expose a parsed ``WalletConnectTransaction`` via
``WalletConnectNotification/transaction``; the full payload is always available as
``WalletConnectNotification/raw`` for other notification types. ``WalletConnectNotificationType``,
like ``WalletConnectMethod`` and ``TransactionState``, keeps values it has no constant for:

```swift
for await notification in try await connection.notifications() {
    switch notification.type {
    case .paymentReceived:
        if let tx = notification.transaction { print("received \(tx.amount) msat") }
    case .paymentSent:
        if let tx = notification.transaction { print("sent \(tx.amount) msat") }
    default:
        print("\(notification.type): \(notification.raw)")
    }
}
```

Multiple concurrent streams are supported; each ends automatically when its task is cancelled or the
connection is disconnected. Arbitrary payload fields are modeled as ``JSONValue``, preserving nested
keys exactly as they appear on the wire.

## Lightning Zap Capstone (NIP-57)

``WalletConnection/payZap(lnurlPay:amountMillisats:zapRequest:lnurl:urlSession:)`` completes a zap
that `NostrCore` can only prepare: it fetches the BOLT-11 invoice from the recipient's LNURL
endpoint and pays it through the wallet in one step. Build the inputs with `NostrCore`:

```swift
// Resolve the recipient's LNURL-pay endpoint and sign the zap request (NostrCore).
guard let serviceURL = LNURL.payServiceURL(forLightningAddress: "alice@example.com") else { return }
let (data, _) = try await URLSession.shared.data(from: serviceURL)
let lnurlPay = try JSONDecoder().decode(LNURLPayResponse.self, from: data)

let signer = EventSigner(keyPair: try KeyPair(nsec: "nsec1..."))
let zapRequest = try signer.sign(.zapRequest(
    to: try PublicKey(npub: "npub1..."),
    relays: [try RelayURL(string: "wss://relay.example.com")],
    amountMillisats: 21_000,
    lnurl: LNURL.encode(serviceURL)))

let zap = try await connection.payZap(
    lnurlPay: lnurlPay,
    amountMillisats: 21_000,
    zapRequest: zapRequest,
    lnurl: LNURL.encode(serviceURL))
print(zap.invoice, zap.preimage, zap.feesPaid ?? 0)
```

An out-of-range amount is rejected before any wallet request is sent. The kind-9735 zap **receipt**
is published by the LNURL provider to the zap request's relays — not to the wallet's NWC relay — so
confirm it with `NostrClient` (subscribe to those relays and validate with
`ZapReceipt(event:)?.validate(lnurlProviderPublicKey:expectedAmountMillisats:requiringDescriptionHash:)`).

## Custom Transport

``WalletConnection`` talks to relays through `NostrCore`'s `RelayTransport` protocol — the same seam
a NIP-46 signer session uses. The default, `RelayConnectionTransport`, drives one `NostrCore` relay
connection per URI relay, sending each request to all of them and merging their events into one
stream. Inject your own transport to run on a different relay stack or to test without a live relay:

```swift
struct InMemoryTransport: RelayTransport {
    func connect() async throws(RelayConnection.Error) { /* ... */ }
    func subscribe(id: SubscriptionID, filters: [Filter]) async throws(RelayConnection.Error) { /* ... */ }
    func unsubscribe(id: SubscriptionID) async { /* ... */ }
    func send(_ event: Event) async throws(RelayConnection.Error) { /* ... */ }
    func events() async -> AsyncStream<Event> { /* ... */ }
    func disconnect() async { /* ... */ }
}

let connection = WalletConnection(uri: uri, transport: InMemoryTransport())
```

To keep the default transport but put it on a different socket — a platform-native WebSocket on a
platform whose Foundation has none, or an in-memory fake in tests — hand it a
`WebSocketSessionFactory` instead:

```swift
let connection = WalletConnection(
    uri: uri,
    transport: RelayConnectionTransport(
        relayURLs: uri.relays, webSocketFactory: OkHttpWebSocketFactory()))
```

NIP-47 request events are ephemeral, so `RelayTransport`'s `send(_:)` is fire-and-forget: the
matching response delivered through its `events()` stream is the completion signal, not a relay
`OK`. Because the seam is platform-independent, a wallet connection runs anywhere `NostrCore` does,
including non-Apple platforms.

## Error Handling

Every command throws ``WalletConnectError``. A wallet that rejects a request reports it as
``WalletConnectError/walletError(code:message:)`` carrying a typed ``WalletConnectErrorCode``.
The set of codes is open-ended, so a code NIP-47 does not define is preserved verbatim in its
``WalletConnectErrorCode/rawValue`` rather than dropped:

```swift
do {
    _ = try await connection.payInvoice("lnbc...")
} catch .walletError(let code, let message) {
    switch code {
    case .insufficientBalance: print("insufficient balance: \(message)")
    case .quotaExceeded:       print("quota exceeded: \(message)")
    case .restricted, .unauthorized: print("not permitted: \(message)")
    default:                   print("\(code.rawValue): \(message)")
    }
} catch .timedOut {
    print("no response within the configured timeout")
} catch .transportFailed(let error) {
    print("the relay failed: \(error)")
} catch {
    print(error)  // any other WalletConnectError
}
```

The other cases — ``WalletConnectError/invalidURI(reason:)``,
``WalletConnectError/requestEncodingFailed``, ``WalletConnectError/responseDecodingFailed``,
``WalletConnectError/missingResult``, ``WalletConnectError/unsupportedEncryption(_:)``,
``WalletConnectError/superseded``, ``WalletConnectError/notConnected``, and
``WalletConnectError/cancelled`` — cover URI parsing, encryption/encoding failures, malformed
responses, a response encrypted with a scheme this package does not implement, a `fetchCapabilities()`
superseded by a newer call, a connection torn down while waiting, and a cancelled task. A request
cancelled after it was sent may still be carried out by the wallet.

## Event Kinds

For low-level work, the module adds the NIP-47 kinds to `NostrCore`'s `Event.Kind`:
`walletConnectInfo` (13194), `walletConnectRequest` (23194), `walletConnectResponse` (23195),
`walletConnectNotificationLegacy` (23196, NIP-04), and `walletConnectNotification` (23197, NIP-44).
``WalletConnection`` handles these for you; reach for them only when building filters or events by
hand.
