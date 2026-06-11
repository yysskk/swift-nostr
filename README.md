# NostrClient

A modern Swift library for the Nostr protocol, built with Swift 6 concurrency support.

## Features

- **Full NIP-01 Support**: Events, subscriptions, and relay communication
- **NIP-02 Contact List**: Follow/unfollow users and manage contact lists
- **NIP-03 OpenTimestamps**: Attach OTS attestations to events
- **NIP-05 Verification**: DNS-based identifier verification
- **NIP-06 Key Derivation**: Generate keys from BIP-39 mnemonic seed phrases
- **NIP-17 Private DMs**: End-to-end encrypted direct messages with sender anonymity
- **Cryptographic Operations**: Schnorr signatures with secp256k1
- **NIP-19 Entities**: bech32 encoding/decoding of npub, nsec, note, nprofile, nevent, and naddr
- **NIP-65 Outbox Model**: Per-user read/write relay lists with gossip routing for subscriptions and publishing
- **Async/Await**: Modern Swift concurrency with actors
- **Multi-Relay Support**: Connect to multiple relays with RelayPool
- **Type-Safe**: Full Sendable compliance for thread safety

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

Or add via Xcode: File → Add Package Dependencies → Enter repository URL.

## Quick Start

### Generate Keys

```swift
import NostrClient

// Generate a new random keypair
let keyPair = try KeyPair()
print("Public Key: \(keyPair.publicKeyHex)")
print("npub: \(keyPair.npub)")
print("nsec: \(keyPair.nsec)")

// Import from nsec
let imported = try KeyPair(nsec: "nsec1...")

// Generate from mnemonic (NIP-06)
let (mnemonic, keyPairFromMnemonic) = try KeyPair.generate(wordCount: 12)
print("Mnemonic: \(mnemonic.phrase)")
print("Public Key: \(keyPairFromMnemonic.npub)")

// Restore from existing mnemonic
let restored = try KeyPair(mnemonicPhrase: "leader monkey parrot ring guide accident before fence cannon height naive bean")
```

### NIP-19 Entities

```swift
// Decode any bech32 entity: npub, nsec, note, nprofile, nevent, naddr
let entity = try NIP19Entity.decode("nprofile1...")

// Encode a reference, optionally with relay hints
let nprofile = try NProfile(publicKey: keyPair.publicKeyHex, relays: ["wss://relay.damus.io"]).encoded
```

`NEvent`, `NAddr`, and the full decoding API are covered in [Advanced Usage](https://yysskk.github.io/swift-nostr-client/documentation/nostrclient/advancedusage).

### Connect to Relays

```swift
let client = NostrClient()

// Add relays and connect in one step
try await client.connect(to: [
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band"
])

// Or separately: addRelays(_:) then connect()
```

### Publish Events

```swift
// Set your private key
try await client.setNsec("nsec1...")

// Publish a text note — returns the signed event plus the per-relay outcome
let note = try await client.publishTextNote(content: "Hello, Nostr!")
print("Accepted by \(note.result.acceptedRelays.count) relay(s)")

// Publish with tags
let tagged = try await client.publishTextNote(
    content: "Check out #nostr",
    tags: [.hashtag("nostr")]
)

// Wait for more acknowledgments before returning
try await client.publishTextNote(content: "Important!", strategy: .quorum(2))

// React to an event
try await client.publishReaction(to: note.event, content: "🤙")
```

### Subscribe to Events

Subscriptions are async sequences — iterate them with `for await`. The
subscription is closed automatically when the loop ends or its task is
cancelled.

```swift
// Subscribe to a user's notes
let timeline = try await client.subscribeToUserTimeline(pubkey: "...")
for await event in timeline.events {
    print("New note: \(event.content)")
}

// Custom filter subscription, events only
let filter = Filter(
    kinds: [1],
    authors: ["pubkey1", "pubkey2"],
    limit: 100
)
for await event in try await client.events(filters: [filter]) {
    print("Received: \(event.id)")
}

// Relay-aware subscription: EOSE, notices, and auth challenges per relay
let subscription = try await client.subscribe(filters: [filter])
for await item in subscription {
    switch item {
    case .event(let relayURL, let event):
        print("[\(relayURL)] \(event.content)")
    case .eose(let relayURL):
        print("[\(relayURL)] end of stored events")
    default:
        break
    }
}

// Close explicitly (or just break out of the loop / cancel the task)
await subscription.close()
```

### Fetch Events

```swift
// Fetch specific event
let event = try await client.fetchEvent(id: "eventid...")

// Fetch user metadata
let metadata = try await client.fetchMetadata(pubkey: "...")
print("Name: \(metadata?.name ?? "Unknown")")
```

### Private Direct Messages (NIP-17)

```swift
// Send (encrypted, gift-wrapped, with a self-copy for sent history)
try await client.sendDirectMessage("Hello privately!", to: "recipientPubkeyHex")

// Receive, already decrypted and parsed
for await message in try await client.directMessages() {
    print("\(message.senderPubkey): \(message.content)")
}
```

### Relay Information (NIP-11)

```swift
let info = try await RelayInformation.fetch(fromRelayURLString: "wss://relay.damus.io")
print(info.name ?? "unknown", info.supportedNIPs ?? [])
```

### Outbox Model (NIP-65)

The outbox/gossip model routes reads and writes to each user's declared relays instead of
broadcasting everywhere. Publish your relay list (kind 10002), then let the client resolve and
connect the right relays automatically.

```swift
// Publish your own relay list: where you read (inbox) and write (outbox)
try await client.publishRelayList(
    read: ["wss://inbox.example.com"],
    write: ["wss://relay.damus.io", "wss://nos.lol"]
)

// Fetch another user's relay list (cached for routing)
let relayList = try await client.fetchRelayList(for: "pubkey...")
print("Writes to: \(relayList?.writeRelays ?? [])")

// Outbox read: subscribe to authors on *their* write relays,
// resolving and connecting relays on demand
let outbox = try await client.subscribeOutbox(authors: ["pubkey1", "pubkey2"])
for await event in outbox.events {
    print("Note: \(event.content)")
}

// Gossip publish: route an event to the author's write relays plus the
// inbox (read) relays of every pubkey it mentions in "p" tags
let signer = EventSigner(keyPair: keyPair)
let note = try signer.signTextNote(content: "gm!", tags: [.pubkey("alice_pubkey")])
try await client.publishGossip(note)
```

By default the client adds and connects resolved relays on demand (capped per resolve). Pass
`gossipPolicy: .requirePresent` to `NostrClient(...)` to route only to relays already in the pool.

## Models

### Event

```swift
public struct Event: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int64
    public let kind: Kind            // RawRepresentable struct; integer literals convert
    public let tags: [[String]]
    public let content: String
    public let sig: String
}
```

### Filter

```swift
public struct Filter: Codable, Sendable, Hashable {
    public var ids: [String]?
    public var authors: [String]?
    public var kinds: [Event.Kind]?
    public var eventReferences: [String]?    // #e
    public var pubkeyReferences: [String]?   // #p
    public var since: Int64?
    public var until: Int64?
    public var limit: Int?
}
```

### Event Kinds

```swift
Event.Kind.setMetadata          // 0
Event.Kind.textNote             // 1
Event.Kind.recommendRelay       // 2
Event.Kind.contacts             // 3
Event.Kind.eventDeletion        // 5
Event.Kind.repost               // 6
Event.Kind.reaction             // 7
Event.Kind.seal                 // 13 (NIP-59)
Event.Kind.privateDirectMessage // 14 (NIP-17)
Event.Kind.giftWrap             // 1059 (NIP-59)
Event.Kind.zapRequest           // 9734
Event.Kind.zap                  // 9735

// Kinds are open-ended: any integer works
let custom = Event.Kind(rawValue: 30311)
let literal: Event.Kind = 1     // == .textNote

// NIP-01 range semantics
Event.Kind.relayListMetadata.isReplaceable  // true
custom.isAddressable                        // true (30000-39999)
// ... and more
```

## Low-Level API

### Direct Relay Connection

```swift
let connection = try RelayConnection(urlString: "wss://relay.damus.io")
await connection.connect()

// Subscribe
try await connection.subscribe(
    subscriptionId: "sub1",
    filters: [Filter(kinds: [1], limit: 10)]
)

// Listen for messages
for await message in await connection.messages() {
    switch message {
    case .event(let subId, let event):
        print("Event: \(event.content)")
    case .endOfStoredEvents(let subId):
        print("EOSE for \(subId)")
    case .notice(let msg):
        print("Notice: \(msg)")
    default:
        break
    }
}
```

### Manual Event Signing

```swift
let keyPair = try KeyPair()
let signer = EventSigner(keyPair: keyPair)

let unsigned = UnsignedEvent(
    pubkey: keyPair.publicKeyHex,
    kind: .textNote,
    tags: [.hashtag("test")],
    content: "Manual signing example"
)

let signed = try signer.sign(unsigned)

// Verify signature
let isValid = try signed.verify()
```

## Supported NIPs

- [x] NIP-01: Basic protocol
- [x] NIP-02: Contact list and petnames
- [x] NIP-03: OpenTimestamps attestations
- [x] NIP-05: DNS-based identifiers
- [x] NIP-06: Basic key derivation from mnemonic seed phrase
- [x] NIP-09: Event deletion
- [x] NIP-10: Reply threading (root/reply markers)
- [x] NIP-11: Relay information document
- [x] NIP-17: Private direct messages
- [x] NIP-18: Reposts
- [x] NIP-19: bech32-encoded entities (npub, nsec, note, nprofile, nevent, naddr)
- [x] NIP-20: Command Results (OK)
- [x] NIP-25: Reactions
- [x] NIP-42: Authentication (AUTH message parsing)
- [x] NIP-44: Versioned encryption
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
