# Nostr Client

Swift library for Nostr protocol

📖 **[API documentation](https://yysskk.github.io/swift-nostr-client/documentation/)** — a combined index for all three libraries, with a [Getting Started](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient/gettingstarted) guide, in-depth [Advanced Usage](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient/advancedusage), and reference docs for every type.

## Features

- **Full NIP-01 Support**: Events, subscriptions, and relay communication
- **NIP-02 Contact List**: Follow/unfollow users and manage contact lists
- **NIP-03 OpenTimestamps**: Attach OTS attestations to events
- **NIP-05 Verification**: DNS-based identifier verification
- **NIP-06 Key Derivation**: Generate keys from BIP-39 mnemonic seed phrases
- **NIP-17 Private DMs**: End-to-end encrypted direct messages with sender anonymity, kind 10050 DM relay routing, reactions, and encrypted file messages
- **NIP-40 Expiration**: Disappearing messages via an expiration timestamp, including private DMs
- **NIP-42 Authentication**: Relay AUTH challenges answered automatically, with auth-required retry
- **NIP-57 Zaps**: Full Lightning zap flow — sign zap requests (kind 9734), resolve LNURL-pay endpoints, fetch invoices, decode bolt11, and verify kind-9735 zap receipts
- **NIP-47 Nostr Wallet Connect**: Pay Lightning invoices through a remote wallet over Nostr — the full command set, NIP-44/NIP-04 encryption, notifications, and one-call zap payment (separate `NostrWalletConnect` library)
- **NIP-19 Entities**: bech32 encoding/decoding of npub, nsec, note, nprofile, nevent, and naddr
- **NIP-65 Outbox Model**: Per-user read/write relay lists with gossip routing for subscriptions and publishing
- **Cryptographic Operations**: Schnorr signatures with secp256k1
- **Async/Await**: Modern Swift concurrency, actor-isolated and fully `Sendable`
- **Multi-Relay Support**: Connect to multiple relays with `RelayPool`

See the [full list of supported NIPs](#supported-nips) below.

## Requirements

- Swift 6.2+
- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+ / visionOS 1.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yysskk/swift-nostr-client", from: "1.0.0")
]
```

Or add via Xcode: File → Add Package Dependencies → Enter the repository URL.

### Library structure

The package vends three libraries:

- **`NostrCore`** — the shared protocol primitives, cryptography, NIP-19 encoding, and a single-relay WebSocket transport: `Event`, `KeyPair`, `EventSigner`, `Filter`, `Bech32`, `SealedMessage`, `RelayConnection`, and the relay messages. Depend on it directly if that is all you need.
- **`NostrClient`** — the high-level, actor-based client (multi-relay pool, NIP-65 outbox/gossip, NIP-17 direct messages, fetches, NIP-19 entities, zap receipts). It is built on `NostrCore` but does not re-export it; add the `NostrCore` product too and import both.
- **`NostrWalletConnect`** — NIP-47 wallet payments, built on `NostrCore`. Its API surfaces core types (`LNURLPayResponse`, `Event`, …), so add the `NostrCore` product and `import NostrCore` alongside it.

> **Migrating from an earlier release:** the protocol primitives moved out of `NostrClient` into the new `NostrCore` module. Add the `NostrCore` product to your target and `import NostrCore` alongside `import NostrClient` wherever you reference `Event`, `KeyPair`, `EventSigner`, `Filter`, `RelayConnection`, `Bech32`, `NostrError`, and the other primitives — the higher-level `NostrClient` API (the `NostrClient` actor, `RelayPool`, direct messages, outbox) is unchanged.

## Quick Start

### Generate keys

```swift
import NostrClient  // the high-level client
import NostrCore    // primitives: KeyPair, Event, Filter, EventSigner, …

let keyPair = try KeyPair()               // new random keypair
print(keyPair.npub, keyPair.nsec)

let imported = try KeyPair(nsec: "nsec1...")

// From a BIP-39 mnemonic (NIP-06)
let (mnemonic, derived) = try KeyPair.generate(wordCount: 12)
print(mnemonic.phrase, derived.npub)
```

### Connect and publish

```swift
let client = NostrClient()
try await client.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])
try await client.setNsec("nsec1...")

// Publish a text note — returns the signed event plus the per-relay outcome.
let note = try await client.publishTextNote(content: "Hello, Nostr!")
print("Accepted by \(note.result.acceptedRelays.count) relay(s)")

try await client.publishReaction(to: note.event, content: "🤙")
```

`PublishStrategy` controls how many acknowledgments a publish waits for (`.firstAck`, `.quorum(n)`, `.allSettled`); the returned `PublishResult` reports the per-relay outcome.

### Subscribe and fetch

Subscriptions are async sequences — iterate them with `for await`. The subscription closes automatically when the loop ends or its task is cancelled.

```swift
// Live timeline
let timeline = try await client.subscribeToUserTimeline(pubkey: "...")
for await event in timeline.events {
    print(event.content)
}

// Custom filter
let filter = Filter(kinds: [1], authors: ["pubkey1"], limit: 100)
for await event in try await client.events(filters: [filter]) {
    print(event.id)
}

// One-shot fetch
let metadata = try await client.fetchMetadata(pubkey: "...")
print(metadata?.name ?? "Unknown")
```

Need per-relay EOSE, notices, and auth challenges? Iterate `client.subscribe(filters:)` directly — see [Advanced Usage](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient/advancedusage).

### Private direct messages (NIP-17)

```swift
// Advertise where you receive DMs (kind 10050; NIP-17 suggests 1–3 relays), then connect your inbox.
try await client.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])
try await client.connectDirectMessageInboxRelays()

// Receive — already decrypted and parsed.
for await message in try await client.directMessages() {
    print("\(message.senderPubkey): \(message.content)")
}

// Send (encrypted, gift-wrapped, routed to each party's DM relays).
try await client.sendDirectMessage("Hello privately!", to: "recipientPubkeyHex")
```

Reactions (NIP-25), encrypted file messages (kind 15), and disappearing messages (NIP-40) build on the same flow — see [Advanced Usage](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient/advancedusage).

### Pay a zap through a remote wallet (NIP-47)

The `NostrWalletConnect` library pays Lightning invoices through a remote wallet, completing the zap flow that `NostrClient` can only prepare. See its [API documentation](https://yysskk.github.io/swift-nostr-client/documentation/nostrwalletconnect) — a [Getting Started](https://yysskk.github.io/swift-nostr-client/documentation/nostrwalletconnect/gettingstarted) guide and in-depth [Advanced Usage](https://yysskk.github.io/swift-nostr-client/documentation/nostrwalletconnect/advancedusage).

```swift
import NostrWalletConnect

// Connect with the wallet's nostr+walletconnect:// string.
let connection = WalletConnection(uri: try WalletConnectURI(string: "nostr+walletconnect://..."))

// Pay any invoice and get the preimage back.
let payment = try await connection.payInvoice("lnbc...")
print(payment.preimage)

// Or complete a zap end to end: fetch the recipient's invoice and pay it.
let zap = try await connection.payZap(
    lnurlPay: lnurlPay,            // resolved LNURLPayResponse
    amountMillisats: 21_000,
    zapRequest: zapRequest)        // signed with EventSigner.signZapRequest(...)
print(zap.preimage)
```

`get_balance`, `get_info`, `make_invoice`, `lookup_invoice`, `list_transactions`, keysend, and multi-payments are available too, along with a `notifications()` stream.

## More

Each of these is covered in depth, with worked examples, in the [documentation](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient):

- **Lightning Zaps (NIP-57)** — resolve an LNURL-pay endpoint, sign a zap request, fetch the bolt11 invoice, and verify the kind-9735 receipt.
- **Outbox model (NIP-65)** — publish your read/write relay list and route reads/writes to each user's declared relays with `subscribeOutbox` / `publishGossip`.
- **Client authentication (NIP-42)** — AUTH challenges are answered automatically once a signer is set, with auth-required publish retry; an opt-in manual mode is available.
- **Relay information (NIP-11)** — fetch a relay's capabilities with `RelayInformation.fetch(fromRelayURLString:)`.
- **NIP-19 entities** — encode/decode `npub`/`nsec`/`note`/`nprofile`/`nevent`/`naddr` via `NIP19Entity`, `NProfile`, `NEvent`, and `NAddr`.
- **Low-level APIs** — drive a single `RelayConnection` directly, or sign events by hand with `EventSigner`.

## Supported NIPs

- [x] NIP-01: Basic protocol
- [x] NIP-02: Contact list and petnames
- [x] NIP-03: OpenTimestamps attestations
- [x] NIP-05: DNS-based identifiers
- [x] NIP-06: Basic key derivation from mnemonic seed phrase
- [x] NIP-09: Event deletion
- [x] NIP-10: Reply threading (root/reply markers)
- [x] NIP-11: Relay information document
- [x] NIP-17: Private direct messages (kind 10050 DM relay lists, encrypted kind 15 file messages)
- [x] NIP-18: Reposts
- [x] NIP-19: bech32-encoded entities (npub, nsec, note, nprofile, nevent, naddr)
- [x] NIP-20: Command Results (OK)
- [x] NIP-25: Reactions (incl. gift-wrapped private DM reactions)
- [x] NIP-40: Expiration timestamp (disappearing messages)
- [x] NIP-42: Client authentication (automatic challenge response, auth-required retry)
- [x] NIP-44: Versioned encryption
- [x] NIP-47: Nostr Wallet Connect (full command set, NIP-44/NIP-04 encryption, notifications, end-to-end zap payment — separate `NostrWalletConnect` library)
- [x] NIP-57: Lightning Zaps (zap request kind 9734, LNURL helpers, invoice fetch, bolt11 decoding, kind-9735 receipt validation)
- [x] NIP-59: Gift wrap
- [x] NIP-65: Relay list metadata (outbox model)

## Development

This project uses [swift-format](https://github.com/swiftlang/swift-format) (bundled with the Swift toolchain) for code formatting. The configuration lives in [`.swift-format`](.swift-format) and is enforced in CI.

```bash
# Format the code in place
swift format --in-place --recursive --parallel Sources Tests Package.swift

# Check formatting without modifying files (matches CI)
swift format lint --strict --recursive --parallel Sources Tests Package.swift
```

## License

MIT License
