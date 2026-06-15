# Advanced Usage

Encryption negotiation, the full command set, notifications, custom transports, and error handling.

## Connection Configuration

``WalletConnection/Config`` tunes how a connection behaves. Pass it to the initializer:

```swift
let config = WalletConnection.Config(
    requestTimeout: 30,             // seconds to wait for a response before failing
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
let info = try await connection.fetchInfo()   // cached; later commands use the negotiated scheme
print(info.negotiatedEncryption)              // .nip44 when supported, else .nip04
```

``WalletConnection/fetchInfo()`` fetches the wallet's info event (kind 13194) and caches it, so
subsequent commands automatically use ``WalletInfo/negotiatedEncryption``. An explicit
``WalletConnection/Config/preferredEncryption`` always wins over negotiation.

## Inspecting Wallet Capabilities

``WalletInfo`` describes what a wallet supports. Use it to gate features before issuing a command
that the wallet would reject:

```swift
let info = try await connection.fetchInfo()

if info.supports(.payInvoice) {
    let payment = try await connection.payInvoice("lnbc...")
    print(payment.preimage)
}

print("Methods:", info.methods)              // recognized commands
print("Unknown methods:", info.unknownMethods) // tokens this library does not model
print("Encryptions:", info.encryptions)      // never empty; defaults to [.nip04]
print("Notifications:", info.notifications)   // e.g. ["payment_received", "payment_sent"]
```

## Invoices and Balance

```swift
// Create an invoice to receive a payment.
let created = try await connection.makeInvoice(
    MakeInvoiceParams(amount: 21_000, description: "coffee", expiry: 3600))
print(created.invoice ?? "")   // a WalletConnectTransaction

// Look up an invoice — by payment hash or by BOLT-11 string. The type guarantees exactly one key.
let byHash = try await connection.lookupInvoice(.paymentHash("abc123..."))
let byBolt11 = try await connection.lookupInvoice(.invoice("lnbc..."))
print(byHash.state ?? "", byBolt11.amount)

// Balance, in millisatoshis.
let balance = try await connection.getBalance()
print("\(balance.balance) msat")
```

## Listing Transactions

``WalletConnection/listTransactions(_:)`` returns matching ``WalletConnectTransaction`` values,
newest first. Filter by time window, direction, paid/unpaid, and paginate with `limit` / `offset`:

```swift
let outgoing = try await connection.listTransactions(
    ListTransactionsParams(limit: 50, type: .outgoing))
for tx in outgoing {
    print("\(tx.type) \(tx.amount) msat — \(tx.state ?? "?")")
}
```

## Keysend Payments

A keysend is a spontaneous payment to a node's public key, with no invoice. Attach optional
``TLVRecord`` values for application data:

```swift
let result = try await connection.payKeysend(
    PayKeysendParams(
        amount: 10_000,
        pubkey: "destinationNodePubkeyHex",
        tlvRecords: [TLVRecord(type: 696969, value: "68656c6c6f")]))
print(result.preimage)
```

## Multi-Payments

``WalletConnection/multiPayInvoice(_:)`` and ``WalletConnection/multiPayKeysend(_:)`` send several
payments in one request. The wallet replies with one response per item, so results come back as a
dictionary keyed by each item's `id` (falling back to the payment hash). Items that never get a
response — for example on a partial timeout — are simply absent, so inspect each entry's `Result`:

```swift
let results = try await connection.multiPayInvoice([
    .init(id: "rent", invoice: "lnbc1..."),
    .init(id: "coffee", invoice: "lnbc2..."),
])
for (id, outcome) in results {
    switch outcome {
    case .success(let payment): print("\(id): paid, preimage \(payment.preimage)")
    case .failure(let error):   print("\(id): \(error.localizedDescription)")
    }
}
```

Unlike single commands, a multi-payment does not throw on timeout — it returns whatever responses
arrived, so a slow or unreachable item does not lose the payments that already settled.

## Notifications

``WalletConnection/notifications()`` returns an `AsyncStream` of ``WalletConnectNotification`` values
(wallet events of kind 23197 for NIP-44 or 23196 for NIP-04), decrypted and parsed. Standard
`payment_received` / `payment_sent` notifications expose a parsed ``WalletConnectTransaction`` via
``WalletConnectNotification/transaction``; the full payload is always available as
``WalletConnectNotification/raw`` for other notification types:

```swift
for await notification in try await connection.notifications() {
    switch notification.type {
    case "payment_received":
        if let tx = notification.transaction { print("received \(tx.amount) msat") }
    case "payment_sent":
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
let zapRequest = try signer.signZapRequest(
    recipientPubkey: "recipientPubkeyHex",
    relays: ["wss://relay.example.com"],
    amountMillisats: 21_000,
    lnurl: LNURL.encode(serviceURL))

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
`ZapReceipt(event:)?.validate(lnurlProviderPubkey:expectedAmountMillisats:)`).

## Custom Transport

``WalletConnection`` talks to relays through the ``WalletConnectTransport`` protocol. The default,
``RelayConnectionTransport``, drives `NostrCore`'s relay connections over the URI's relays.
Inject your own transport to run on a different relay stack or to test without a live relay:

```swift
struct InMemoryTransport: WalletConnectTransport {
    func connect() async throws { /* ... */ }
    func subscribe(id: String, filters: [Filter]) async throws { /* ... */ }
    func unsubscribe(id: String) async { /* ... */ }
    func send(_ event: Event) async throws { /* ... */ }
    func events() async -> AsyncStream<Event> { /* ... */ }
    func disconnect() async { /* ... */ }
}

let connection = WalletConnection(uri: uri, transport: InMemoryTransport())
```

NIP-47 request events are ephemeral, so ``WalletConnectTransport/send(_:)`` is fire-and-forget: the
matching response delivered through ``WalletConnectTransport/events()`` is the completion signal, not
a relay `OK`. Because the seam is platform-independent, a wallet connection runs anywhere
`NostrCore` does, including non-Apple platforms.

## Error Handling

Every command throws ``WalletConnectError``. A wallet that rejects a request reports it as
``WalletConnectError/walletError(code:message:)`` carrying a typed ``WalletConnectErrorCode`` —
unrecognized codes are preserved as ``WalletConnectErrorCode/unknown(_:)`` rather than dropped:

```swift
do {
    _ = try await connection.payInvoice("lnbc...")
} catch let WalletConnectError.walletError(code, message) {
    switch code {
    case .insufficientBalance: print("insufficient balance: \(message)")
    case .quotaExceeded:       print("quota exceeded: \(message)")
    case .restricted, .unauthorized: print("not permitted: \(message)")
    case .unknown(let raw):    print("unmodeled code \(raw): \(message)")
    default:                   print("\(code.rawValue): \(message)")
    }
} catch WalletConnectError.timedOut {
    print("no response within the configured timeout")
} catch WalletConnectError.notConnected {
    print("the connection was torn down")
}
```

The other cases — ``WalletConnectError/invalidURI(reason:)``,
``WalletConnectError/requestEncodingFailed``, ``WalletConnectError/responseDecodingFailed``,
``WalletConnectError/missingResult``, and ``WalletConnectError/superseded`` — cover URI parsing,
encryption/encoding failures, malformed responses, and a `fetchInfo()` superseded by a newer call.

## Event Kinds

For low-level work, the module adds the NIP-47 kinds to `NostrCore`'s `Event.Kind`:
`walletConnectInfo` (13194), `walletConnectRequest` (23194), `walletConnectResponse` (23195),
`walletConnectNotificationLegacy` (23196, NIP-04), and `walletConnectNotification` (23197, NIP-44).
``WalletConnection`` handles these for you; reach for them only when building filters or events by
hand.
