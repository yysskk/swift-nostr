# Getting Started

Connect to a wallet service and pay your first invoice.

## Installation

NostrWalletConnect ships in the same package as `NostrClient`. Add the package dependency in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yysskk/swift-nostr", from: "0.5.0")
]
```

Then add the `NostrWalletConnect` product to your target. It re-exports the `NostrCore`
primitives its API surfaces (events, keys, `LNURLPayResponse`, …):

```swift
.target(
    name: "YourTarget",
    dependencies: ["NostrWalletConnect"]
)
```

If you also need the higher-level `NostrClient` features (the `NostrClient` actor, direct messages,
zap receipts, NIP-19 entities), add the `NostrClient` product as a separate dependency.

Or add via Xcode: File → Add Package Dependencies → Enter the repository URL.

## Connect to a Wallet

A wallet service authorizes a client by issuing a `nostr+walletconnect://` connection string. Parse
it into a ``WalletConnectURI`` and create a ``WalletConnection``:

```swift
import NostrWalletConnect

let uri = try WalletConnectURI(string: "nostr+walletconnect://...")
let connection = WalletConnection(uri: uri)
```

The connection string's host is the wallet service's public key, held as a `PublicKey` in
``WalletConnectURI/walletPublicKey``. It must be canonical lowercase hex: anything else, uppercase hex
included, throws ``WalletConnectError/invalidURI(reason:)``.

The URI carries a per-client secret key, so the wallet connection signs and encrypts with a key
dedicated to this app — the user's main Nostr identity is never exposed. Commands connect to the
relay automatically on first use; call ``WalletConnection/connect()`` explicitly to surface
connection errors up front.

## Pay an Invoice

``WalletConnection/payInvoice(_:amount:)`` asks the wallet to pay a BOLT-11 invoice and returns the
payment preimage:

```swift
let payment = try await connection.payInvoice("lnbc...")
print("Preimage: \(payment.preimage)")
print("Fees paid: \(payment.feesPaid ?? 0) msat")
```

## Pay a Zap End to End

The headline use case: hand the connection a recipient's resolved LNURL-pay response and a signed
zap request, and ``WalletConnection/payZap(lnurlPay:amountMillisats:zapRequest:lnurl:urlSession:)``
fetches the invoice and pays it in one step. Build the zap request with `NostrCore`
(`LNURL`, `KeyPair`, and `EventSigner` come from there):

```swift
// Resolve the recipient's LNURL-pay endpoint (NostrCore).
guard let serviceURL = LNURL.payServiceURL(forLightningAddress: "alice@example.com") else { return }
let (data, _) = try await URLSession.shared.data(from: serviceURL)
let lnurlPay = try JSONDecoder().decode(LNURLPayResponse.self, from: data)

// Sign a zap request (kind 9734) — it is not published to relays.
let keyPair = try KeyPair(nsec: "nsec1...")   // the zapping user's key
let signer = EventSigner(keyPair: keyPair)
let zapRequest = try await signer.sign(.zapRequest(
    to: try PublicKey(npub: "npub1..."),
    relays: [try RelayURL(string: "wss://relay.example.com")],
    amountMillisats: 21_000,
    lnurl: LNURL.encode(serviceURL),
    comment: "great post!"))

// Fetch the invoice and pay it through the wallet in one call.
let zap = try await connection.payZap(
    lnurlPay: lnurlPay,
    amountMillisats: 21_000,
    zapRequest: zapRequest,
    lnurl: LNURL.encode(serviceURL))
print("Zap preimage: \(zap.preimage)")
```

## Query the Wallet

```swift
let balance = try await connection.fetchBalance()
print("Balance: \(balance.balance) msat")

let info = try await connection.fetchNodeInfo()
print("Node alias: \(info.alias ?? "unknown")")
print("Supported methods: \(info.methods)")
```

Each of these commands sends a ``WalletConnectRequest`` value through ``WalletConnection/send(_:)``,
which you can call directly — with a built-in request such as ``GetBalanceRequest``, or with a
request type of your own for a command this package does not wrap (see <doc:AdvancedUsage>):

```swift
let balance = try await connection.send(GetBalanceRequest())
```

## Listen for Notifications

``WalletConnection/notifications()`` streams wallet notifications (e.g. `payment_received`,
`payment_sent`) as they arrive. Standard payment notifications expose a parsed
``WalletConnectTransaction`` via ``WalletConnectNotification/transaction``:

```swift
for await notification in try await connection.notifications() {
    print("Notification: \(notification.type)")
    if let tx = notification.transaction {
        print("\(tx.type) \(tx.amount) msat")
    }
}
```

## Handle Errors

Commands throw ``WalletConnectError``. A wallet that rejects a request reports it as
``WalletConnectError/walletError(code:message:)`` with a typed ``WalletConnectErrorCode``:

```swift
do {
    let payment = try await connection.payInvoice("lnbc...")
    print(payment.preimage)
} catch let WalletConnectError.walletError(code, message) {
    switch code {
    case .insufficientBalance: print("Not enough balance: \(message)")
    case .paymentFailed: print("Payment failed: \(message)")
    default: print("Wallet error \(code.rawValue): \(message)")
    }
} catch WalletConnectError.timedOut {
    print("The wallet did not respond in time")
}
```

## Next Steps

When you are done, release the connection's relay resources and in-flight work with
``WalletConnection/disconnect()``.
