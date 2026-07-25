# Getting Started

Generate keys, sign an event, and talk to a single relay with the core primitives.

## Installation

NostrCore is a product of the swift-nostr package. Add the package, then the `NostrCore` product to your target:

```swift
.target(
    name: "YourTarget",
    dependencies: ["NostrCore"]
)
```

If you need the higher-level client (relay pool, gossip routing, direct messages) add the `NostrClient` product; for wallet payments add `NostrWalletConnect`. Both are built on NostrCore.

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

## Authorize an HTTP Request

``HTTPAuth`` proves your identity to an HTTP server with a signed kind-27235 event in the `Authorization` header (NIP-98). Sign the final form of the request — the event commits to its exact URL, method, and body — immediately before sending:

```swift
var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
request.httpMethod = "POST"
request.httpBody = body
try await request.setNostrAuthorization(signer: signer)  // any NostrSigning
```

A server (or any verifier) runs the full NIP-98 check chain with ``HTTPAuth/validate(authorization:url:method:payload:tolerance:now:)`` and trusts the returned event's ``Event/pubkey`` as the authenticated identity:

```swift
let event = try HTTPAuth.validate(
    authorization: authorizationHeader, url: requestURL, method: "POST", payload: body)
let authenticatedPubkey = event.pubkey
```

## Join and Post to a Relay-based Group

``Groups`` builds the client side of NIP-29 relay-based groups. A group lives on a single relay, and everything a user sends carries the group id in an "h" tag. Ask to join (kind 9021, with an invite code for closed groups), then post content of any kind — here a NIP-C7 chat message — with "previous" timeline references sampled from recently seen group events:

```swift
let join = try await Groups.joinRequest(groupID: "abcdef", inviteCode: "A7fjq2", signer: signer)

let message = try await Groups.contentEvent(
    groupID: "abcdef",
    kind: .chatMessage,
    content: "hello",
    previous: Groups.previousReferences(from: recentEvents, excludingAuthor: signer.publicKey),
    signer: signer
)
```

The relay answers with the group's state as relay-signed kind-39xxx events, which carry the group id in a "d" tag instead (user-sent events use "h"). Parse them with ``Groups/Metadata`` and its siblings, pinning the author to the relay's pubkey so an impostor's event is rejected:

```swift
let metadata = try Groups.Metadata(event: stateEvent, relayPubkey: relayPubkey)
print(metadata.name ?? metadata.groupID, metadata.isPrivate ? "private" : "public")
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

The message stream survives automatic reconnections; the `for await` loop ends when the
connection is torn down for good — on ``RelayConnection/disconnect()`` or once auto-reconnect
gives up after ``RelayConnectionConfig/maxReconnectAttempts`` failed attempts.

The transport is injectable through ``WebSocketSessionFactory``: the default ``URLSessionWebSocketFactory`` backs it with `URLSession`, while a host can supply a native socket (for example OkHttp on Android) or a test can supply an in-memory fake — so the connection logic runs on platforms whose Foundation lacks WebSocket support.

```swift
struct OkHttpWebSocketFactory: WebSocketSessionFactory {
    func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        OkHttpWebSocket(request: request)   // your WebSocketSession over the platform socket
    }
}

let relay = RelayConnection(
    url: URL(string: "wss://relay.example.com")!,
    webSocketFactory: OkHttpWebSocketFactory()
)
try await relay.connect()
```
