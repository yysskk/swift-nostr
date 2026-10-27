# Getting Started

Install NostrClient and publish your first event.

## Installation

Add the package dependency in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yysskk/swift-nostr", from: "0.5.0")
]
```

Add `NostrClient` to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["NostrClient"]
)
```

Or add via Xcode: File > Add Package Dependencies > Enter the repository URL.

## Generate Keys

```swift
import NostrClient

// Generate a random keypair
let keyPair = KeyPair()
print("npub: \(keyPair.publicKey.npub)")
print("nsec: \(keyPair.nsec)")

// Import from nsec
let imported = try KeyPair(nsec: "nsec1...")

// Generate from BIP-39 mnemonic (NIP-06)
let (mnemonic, keyPairFromMnemonic) = try KeyPair.generate(wordCount: 12)
print("Mnemonic: \(mnemonic.phrase)")
```

## Connect to Relays

```swift
let client = NostrClient()

// Add relays and connect in one step
try await client.relays.connect(to: [
    RelayURL(string: "wss://relay.example.com"),
    RelayURL(string: "wss://relay2.example.com"),
    RelayURL(string: "wss://relay3.example.com"),
])
```

A ``RelayURL`` is validated and normalized when it is created, so `wss://Relay.Example.com/` and
`wss://relay.example.com` name the same pool entry, and every relay-targeted API — `add`, `remove`,
`relay(for:)`, the `to:` targets of publish, fetch, count, and subscribe, and the per-relay keys of
``PublishResult`` — compares relays by that canonical form.

## Publish Events

```swift
try await client.identity.setNsec("nsec1...")

// Text note — returns the signed event plus the per-relay outcome
let note = try await client.events.publishTextNote(content: "Hello, Nostr!")
print("Accepted by \(note.result.acceptedRelays.count) relay(s)")

// Reaction
try await client.events.publishReaction(to: note.event, content: "🤙")

// Reply
try await client.events.publishReply(to: note.event, content: "Great post!")
```

## Subscribe to Events

Subscriptions are async sequences. Iterate ``SubscriptionSequence/events`` for
event payloads only, or the sequence itself for relay-aware items (EOSE,
notices, auth challenges). Ending the loop — or cancelling its task — closes
the subscription automatically.

```swift
// User timeline
let alice = try PublicKey(npub: "npub1...")
let timeline = try await client.subscriptions.userTimeline(publicKey: alice)
for await event in timeline.events {
    print("Note: \(event.content)")
}

// Custom filter, events only
let filter = Filter(authors: [alice], kinds: [1], limit: 100)
for await event in try await client.subscriptions.events(filters: [filter]) {
    print("Received: \(event.id)")
}

// Close explicitly when consuming from another task
let subscription = try await client.subscriptions.subscribe(filters: [filter])
await subscription.close()
```

## Fetch Events

``NostrClient/NostrClient`` provides one-shot fetch methods that open a temporary subscription, collect matching events until all relays signal End of Stored Events (EOSE), then close the subscription and return the results.

```swift
// Fetch a specific event by ID
let event = try await client.events.fetchEvent(id: try EventID(note: "note1..."))

// Fetch user metadata
let metadata = try await client.events.fetchMetadata(publicKey: alice)
print("Name: \(metadata?.name ?? "Unknown")")

// Fetch with custom filters
let events = try await client.events.fetch(filters: [
    Filter(authors: [alice], kinds: [1], limit: 50)
])
```
