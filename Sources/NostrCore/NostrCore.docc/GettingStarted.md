# Getting Started

Generate keys, sign an event, and talk to a single relay with the core primitives.

## Installation

NostrCore is a product of the swift-nostr-client package. Add the package, then the `NostrCore` product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["NostrCore"]
)
```

If you need the higher-level client (relay pool, gossip routing, direct messages) add the `NostrClient` product; for wallet payments add `NostrWalletConnect`. Both are built on NostrCore but do not re-export it — add the `NostrCore` product and `import NostrCore` to use the primitives directly.

## Keys

```swift
import NostrCore

let keyPair = try KeyPair()                  // new random keypair
print(try keyPair.npub, try keyPair.nsec)

let imported = try KeyPair(nsec: "nsec1...")

// From a BIP-39 mnemonic (NIP-06)
let (mnemonic, derived) = try KeyPair.generate(wordCount: 12)
print(mnemonic.phrase, try derived.npub)
```

## Sign and Verify

``EventSigner`` turns an ``UnsignedEvent`` into a signed ``Event``, and ``Event/verify()`` checks an event's id and signature.

```swift
let signer = EventSigner(keyPair: keyPair)

let note = try signer.signTextNote(content: "Hello, Nostr!")
let reaction = try signer.signReaction(to: note, content: "🤙")

// Or build any event yourself.
let custom = try signer.sign(
    UnsignedEvent(pubkey: signer.publicKey, kind: .textNote, content: "gm")
)

let isValid = try note.verify()
assert(isValid)
```

## Talk to a Single Relay

``RelayConnection`` is one actor-isolated relay socket with its own connect/keepalive/reconnect state machine. Open it, publish, and read messages as an async stream.

```swift
let relay = RelayConnection(url: URL(string: "wss://relay.example.com")!)
try await relay.connect()

try await relay.send(.event(note))

try await relay.subscribe(subscriptionId: "sub1", filters: [Filter(kinds: [.textNote], limit: 20)])
for await message in await relay.messages() {
    if case .event(_, let event) = message {
        print(event.content)
    }
}

await relay.disconnect()
```

The transport is injectable through ``WebSocketSessionFactory``: the default ``URLSessionWebSocketFactory`` backs it with `URLSession`, while a host can supply a native socket (for example OkHttp on Android) or a test can supply an in-memory fake — so the connection logic runs on platforms whose Foundation lacks WebSocket support.
