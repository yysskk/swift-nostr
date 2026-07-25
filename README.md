# Swift Nostr

Swift library for Nostr protocol

[![CI](https://github.com/yysskk/swift-nostr/actions/workflows/test.yml/badge.svg)](https://github.com/yysskk/swift-nostr/actions/workflows/test.yml)
[![Release](https://img.shields.io/github/v/release/yysskk/swift-nostr?sort=semver)](https://github.com/yysskk/swift-nostr/releases)
[![Swift 6.3](https://img.shields.io/badge/Swift-6.3-F05138.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%20|%20macOS%20|%20tvOS%20|%20watchOS%20|%20visionOS-blue.svg)](https://github.com/yysskk/swift-nostr)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

📖 **[API documentation](https://yysskk.github.io/swift-nostr/documentation/)** — a combined index for all four libraries, with a [Getting Started](https://yysskk.github.io/swift-nostr/documentation/nostrclient/gettingstarted) guide, in-depth [Advanced Usage](https://yysskk.github.io/swift-nostr/documentation/nostrclient/advancedusage), and reference docs for every type.

## Features

- **Full NIP-01 Support**: Events, subscriptions, and relay communication
- **NIP-02 Contact List**: Follow/unfollow users and manage contact lists
- **NIP-03 OpenTimestamps**: Attach OTS attestations to events
- **NIP-05 Verification**: DNS-based identifier verification
- **NIP-06 Key Derivation**: Generate keys from BIP-39 mnemonic seed phrases
- **NIP-17 Private DMs**: End-to-end encrypted direct messages with sender anonymity, kind 10050 DM relay routing, reactions, and encrypted file messages
- **NIP-40 Expiration**: Disappearing messages via an expiration timestamp, including private DMs
- **NIP-42 Authentication**: Relay AUTH challenges answered automatically, with auth-required retry
- **NIP-29 Relay-based Groups**: Join, chat in, and moderate groups managed by a single relay — `naddr` share links with invite codes, timeline references, relay-signed state parsing, and the kind-10009 simple group list
- **NIP-98 HTTP Auth**: Sign `Authorization: Nostr` headers for HTTP requests with any signer, and validate them server-side
- **NIP-57 Zaps**: Full Lightning zap flow — sign zap requests (kind 9734), resolve LNURL-pay endpoints, fetch invoices, decode bolt11, and verify kind-9735 zap receipts
- **NIP-47 Nostr Wallet Connect**: Pay Lightning invoices through a remote wallet over Nostr — the full command set, NIP-44/NIP-04 encryption, notifications, and one-call zap payment (separate `NostrWalletConnect` library)
- **NIP-46 Nostr Connect**: Delegate signing to a remote signer that holds the user's key — both the signer-initiated `bunker://` and client-initiated `nostrconnect://` flows, `auth_url` challenges, and typed commands for signing, encryption, and key proof (separate `NostrConnect` library)
- **NIP-19 Entities**: bech32 encoding/decoding of npub, nsec, note, nprofile, nevent, and naddr
- **NIP-49 Private Key Encryption**: Password-encrypt a private key to an `ncryptsec` string with scrypt and XChaCha20-Poly1305
- **NIP-65 Outbox Model**: Per-user read/write relay lists with gossip routing for subscriptions and publishing
- **Cryptographic Operations**: Schnorr signatures with secp256k1
- **Async/Await**: Modern Swift concurrency, actor-isolated and fully `Sendable`
- **Multi-Relay Support**: Connect to multiple relays with `RelayPool`

See the [full list of supported NIPs](#supported-nips) below.

## Requirements

- Swift 6.3+
- iOS 17.0+ / macOS 14.0+ / tvOS 17.0+ / watchOS 10.0+ / visionOS 1.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yysskk/swift-nostr", from: "0.6.0")
]
```

Or add via Xcode: File → Add Package Dependencies → Enter the repository URL.

### Library structure

The package vends four libraries:

- **`NostrCore`** — the shared protocol primitives, cryptography, NIP-19 encoding, and a single-relay WebSocket transport: `Event`, `KeyPair`, `EventSigner`, `Filter`, `Bech32`, `SealedMessage`, `RelayConnection`, and the relay messages. Depend on it directly if that is all you need.
- **`NostrClient`** — the high-level, actor-based client (multi-relay pool, NIP-65 outbox/gossip, NIP-17 direct messages, fetches, NIP-19 entities, zap receipts). It is built on `NostrCore`, which it re-exports.
- **`NostrWalletConnect`** — NIP-47 wallet payments. Built on `NostrCore`, which it re-exports.
- **`NostrConnect`** — NIP-46 remote signing (`bunker://` and `nostrconnect://` flows). Built on `NostrCore`, which it re-exports.

> **Migrating from an earlier release:** the protocol primitives (`Event`, `KeyPair`, `EventSigner`, `Filter`, `RelayConnection`, `Bech32`, `NostrError`, …) moved out of `NostrClient` into the new `NostrCore` module, but `NostrClient` re-exports it — existing `import NostrClient` code keeps compiling without changes. Depend on the `NostrCore` product and `import NostrCore` directly only when you use the primitives without the high-level client.

## Quick Start

### Generate keys

```swift
import NostrClient

let keyPair = try KeyPair()               // new random keypair
print(try keyPair.npub, try keyPair.nsec)

let imported = try KeyPair(nsec: "nsec1...")

// From a BIP-39 mnemonic (NIP-06)
let (mnemonic, derived) = try KeyPair.generate(wordCount: 12)
print(mnemonic.phrase, try derived.npub)
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

Need per-relay EOSE, notices, and auth challenges? Iterate `client.subscribe(filters:)` directly — see [Advanced Usage](https://yysskk.github.io/swift-nostr/documentation/nostrclient/advancedusage).

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

Reactions (NIP-25), encrypted file messages (kind 15), and disappearing messages (NIP-40) build on the same flow — see [Advanced Usage](https://yysskk.github.io/swift-nostr/documentation/nostrclient/advancedusage).

### Pay a zap through a remote wallet (NIP-47)

The `NostrWalletConnect` library pays Lightning invoices through a remote wallet, completing the zap flow that `NostrClient` can only prepare. See its [API documentation](https://yysskk.github.io/swift-nostr/documentation/nostrwalletconnect) — a [Getting Started](https://yysskk.github.io/swift-nostr/documentation/nostrwalletconnect/gettingstarted) guide and in-depth [Advanced Usage](https://yysskk.github.io/swift-nostr/documentation/nostrwalletconnect/advancedusage).

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

### Sign remotely with a bunker (NIP-46)

The `NostrConnect` library delegates signing to a remote signer that holds the user's key, so the app never handles an `nsec`. It supports both the signer-initiated `bunker://` flow and the client-initiated `nostrconnect://` flow. See its [API documentation](https://yysskk.github.io/swift-nostr/documentation/nostrconnect) and [Getting Started](https://yysskk.github.io/swift-nostr/documentation/nostrconnect/gettingstarted) guide.

```swift
import NostrConnect

// Start a session from the signer's bunker:// token.
let signer = try RemoteSigner(bunker: try BunkerURI(string: "bunker://..."))

// Prove the user's key and sign an event remotely — the signed event is verified locally.
let userPubkey = try await signer.userPublicKey()
let signed = try await signer.sign(
    UnsignedEvent(pubkey: userPubkey, kind: .textNote, content: "Signed by my bunker"))
print(signed.id, try signed.verify())
```

Or start the handshake from the client: generate a `nostrconnect://` invitation, show it as a QR code or link, and wait for the signer to accept — its pubkey is discovered from the response, which is validated against the invitation secret.

```swift
let invitation = try NostrConnectURI.invitation(clientKeyPair: clientKeyPair, relays: [relayURL])
displayQRCode(invitation.stringValue)

let signer = try RemoteSigner(invitation: invitation, clientKeyPair: clientKeyPair)
let remotePubkey = try await signer.awaitConnection()   // resolves once the signer accepts
```

`ping`, NIP-44/NIP-04 encrypt and decrypt, `switch_relays`, and `logout` are available too, along with an `authChallenges()` stream for `auth_url` approvals.

A `RemoteSigner` can also drive a `NostrClient`: `NostrClient.setSigner(_:)` accepts any `NostrSigning`, so a remote signer works for `sign(_:)`, `publish(_:)`, and NIP-42 authentication. The convenience `publish*` and direct-message helpers still require a local key and throw `NostrError.localSignerRequired` for a remote signer.

```swift
try await client.setSigner(signer)   // any NostrSigning — a RemoteSigner or a local EventSigner
guard let userPubkey = await client.publicKey else { return }
let signed = try await client.sign(
    UnsignedEvent(pubkey: userPubkey, kind: .textNote, content: "Signed by my bunker"))
try await client.publish(signed)
```

### Authorize an HTTP request (NIP-98)

Prove your Nostr identity to an HTTP server with a signed kind-27235 event in the `Authorization` header — no account or session needed. Sign the final form of the request; the event commits to its exact URL, method, and body:

```swift
import NostrCore

var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
request.httpMethod = "POST"
request.httpBody = body
try await request.setNostrAuthorization(signer: signer)  // any NostrSigning
```

On the receiving side, `HTTPAuth.validate` runs the full NIP-98 check chain — scheme, decoding, kind, signature, timestamp window, URL, method, body hash — and returns the verified event, whose `pubkey` is the authenticated identity:

```swift
let event = try HTTPAuth.validate(
    authorization: authorizationHeader, url: requestURL, method: "POST", payload: body)
let authenticatedPubkey = event.pubkey
```

### Relay-based groups (NIP-29)

A NIP-29 group lives on a single relay, which enforces membership and permissions; every group flow targets exactly that relay. Groups are shared as the `naddr` of their kind-39000 metadata event, optionally carrying an invite code:

```swift
import NostrClient

// Parse a share link and join (kind 9021) — the invite code is applied automatically.
let group = try GroupReference(naddrString: "naddr1...?invite=A7fjq2")
try await client.joinGroup(group)

// Follow the live timeline, keeping recent events for timeline references.
var recent: [Event] = []
let timeline = try await client.subscribeToGroupTimeline(group)
for await event in timeline.events {
    recent.append(event)
    print(event.content)
}

// Chat (NIP-C7 kind 9 by default), referencing recent events so rebroadcasts are detectable.
try await client.publishGroupMessage(
    "Hello, group!",
    in: group,
    previous: Groups.previousReferences(from: recent, excludingAuthor: await client.publicKey)
)
```

Private groups require NIP-42 AUTH, which the client answers automatically once a signer is set — no extra code.

## More

Each of these is covered in depth, with worked examples, in the [documentation](https://yysskk.github.io/swift-nostr/documentation/nostrclient):

- **Lightning Zaps (NIP-57)** — resolve an LNURL-pay endpoint, sign a zap request, fetch the bolt11 invoice, and verify the kind-9735 receipt.
- **Outbox model (NIP-65)** — publish your read/write relay list and route reads/writes to each user's declared relays with `subscribeOutbox` / `publishGossip`.
- **Client authentication (NIP-42)** — AUTH challenges are answered automatically once a signer is set, with auth-required publish retry; an opt-in manual mode is available.
- **HTTP authorization (NIP-98)** — sign requests with `URLRequest.setNostrAuthorization(signer:)` or `HTTPAuth`, and validate incoming headers with `HTTPAuth.validate`.
- **Relay-based groups (NIP-29)** — parse `naddr` share links with `GroupReference`, join and leave, chat with timeline references, moderate with `Groups.ModerationAction`, fetch validated relay-signed state with `fetchGroupState`, and keep the kind-10009 simple group list fresh.
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
- [x] NIP-13: Proof of Work
- [x] NIP-17: Private direct messages (kind 10050 DM relay lists, encrypted kind 15 file messages)
- [x] NIP-18: Reposts
- [x] NIP-19: bech32-encoded entities (npub, nsec, note, nprofile, nevent, naddr)
- [x] NIP-20: Command Results (OK)
- [x] NIP-21: nostr: URI scheme
- [x] NIP-23: Long-form content (kind 30023 articles, kind 30024 drafts)
- [x] NIP-25: Reactions (incl. gift-wrapped private DM reactions)
- [x] NIP-27: Text note references
- [x] NIP-29: Relay-based Groups (join/leave, chat, moderation kinds 9000-9002, 9005, 9007-9010, relay-signed state parsing, naddr share links with invite codes; LiveKit AV rooms are not modeled — only the kind-39000 `livekit` flag is parsed)
- [x] NIP-40: Expiration timestamp (disappearing messages)
- [x] NIP-42: Client authentication (automatic challenge response, auth-required retry)
- [x] NIP-44: Versioned encryption
- [x] NIP-45: Event counts (COUNT)
- [x] NIP-46: Nostr Connect (remote signing; bunker:// and nostrconnect:// — separate NostrConnect library)
- [x] NIP-47: Nostr Wallet Connect (full command set, NIP-44/NIP-04 encryption, notifications, end-to-end zap payment — separate `NostrWalletConnect` library)
- [x] NIP-49: Private key encryption (ncryptsec)
- [x] NIP-50: Search capability
- [x] NIP-51: Lists (standard lists + parameterized sets; NIP-44-encrypted private items; kind-10009 simple group list)
- [x] NIP-56: Reporting (kind 1984)
- [x] NIP-57: Lightning Zaps (zap request kind 9734, LNURL helpers, invoice fetch, bolt11 decoding, kind-9735 receipt validation)
- [x] NIP-59: Gift wrap
- [x] NIP-65: Relay list metadata (outbox model)
- [x] NIP-98: HTTP Auth (kind-27235 authorization events, header encoding, server-side validation)

## Development

This project uses [swift-format](https://github.com/swiftlang/swift-format) (bundled with the Swift toolchain) for code formatting. The configuration lives in [`.swift-format`](.swift-format) and is enforced in CI.

```bash
# Format the code in place
swift format --in-place --recursive --parallel Sources Tests Package.swift

# Check formatting without modifying files (matches CI)
swift format lint --strict --recursive --parallel Sources Tests Package.swift
```

## Contributing

Contributions are welcome! See the [contributing guide](CONTRIBUTING.md) for how to build,
test, and submit changes, the [changelog](CHANGELOG.md) for release history, the
[code of conduct](CODE_OF_CONDUCT.md) for community expectations, and the
[security policy](SECURITY.md) for how to report vulnerabilities.

## License

MIT License
