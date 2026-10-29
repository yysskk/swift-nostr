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

let keyPair = KeyPair()                  // new random keypair
print(keyPair.publicKey.npub, keyPair.privateKey.nsec)

let imported = try KeyPair(nsec: "nsec1...")

// From a BIP-39 mnemonic (NIP-06)
let (mnemonic, derived) = try KeyPair.generate(wordCount: .twelve)
print(mnemonic.phrase, derived.publicKey.npub)
```

Public keys, event ids, and signatures are value types — ``PublicKey``, ``EventID``, and ``Signature`` — that hold exactly one spelling: canonical lowercase hex, which is also how they encode to JSON. Parsing anything else (uppercase, the wrong length, non-hex) throws, and ``PublicKey/npub`` / ``EventID/note`` give the NIP-19 forms:

```swift
let publicKey = try PublicKey(npub: "npub1...")
print(publicKey.hex, publicKey.npub)
let id = try EventID(hex: "4cd665db042864ee600ee976d6cfcc7c5ce743859462f94a347cd970d88a5f3b")
print(id.note)
```

A replaceable or addressable event is referenced by its ``EventCoordinate`` — kind, author, and `d`-tag identifier — written `<kind>:<pubkey>:<identifier>` in "a" tags and JSON:

```swift
let coordinate = EventCoordinate(kind: .longFormContent, publicKey: publicKey, identifier: "my-article")
let tag = Tag.address(coordinate)   // ["a", "30023:<pubkey>:my-article"]
let parsed = EventCoordinate("30023:\(publicKey.hex):my-article")   // nil when malformed
```

Times are ``Timestamp`` values: whole Unix seconds, kept exactly as on the wire and encoded to JSON as a bare number. ``Event/createdAt``, ``Filter/since``, ``Filter/until``, and NIP-40 expirations use it, converting to and from `Date` clamps an out-of-range value instead of trapping, and ``Timestamp/advanced(by:)`` and ``Timestamp/duration(to:)`` do arithmetic with `Duration`:

```swift
let dayAgo = Timestamp.now.advanced(by: .seconds(-86_400))
let filter = Filter(kinds: [.textNote], since: dayAgo)
print(Timestamp.now.rawValue, dayAgo.date)
```

## Sign and Verify

An ``EventTemplate`` holds what you decide about an event — its kind, tags, content, and creation time. ``EventSigner`` signs it under its key into a complete ``Event``, and ``Event/verify()`` checks an event's id and signature, throwing if either is wrong — ``Event/isValid`` is the same check as a `Bool`.

```swift
let signer = EventSigner(keyPair: keyPair)

let note = signer.sign(.textNote("Hello, Nostr!"))
let reaction = signer.sign(.reaction(to: note, content: "🤙"))
let reply = signer.sign(.reply(to: note, content: "gm to you too"))  // NIP-10 threading

// Or build any event yourself. Tags that reference an event or a key take the typed value.
let custom = signer.sign(
    EventTemplate(
        kind: .textNote,
        tags: [.event(note.id, marker: .reply), .publicKey(note.publicKey)],
        content: "gm")
)

try note.verify()
```

A template's properties are mutable, so a factory's result can be adjusted before signing:

```swift
var expiring = EventTemplate.textNote("gone in an hour")
expiring.tags.append(.expiration(.now.advanced(by: .seconds(3600))))
let event = signer.sign(expiring)
```

Templates work with any ``NostrSigning``, including a remote NIP-46 signer, through ``NostrSigning/sign(_:)-(EventTemplate)``; ``NostrSigning/sign(_:proofOfWork:)`` mines one to a NIP-13 difficulty before signing it:

```swift
let zapRequest = try await remoteSigner.sign(.zapRequest(to: recipient, relays: [relay]))
let mined = try await signer.sign(.textNote("worked for"), proofOfWork: 20)
```

## Authorize an HTTP Request

``HTTPAuth`` proves your identity to an HTTP server with a signed kind-27235 event in the `Authorization` header (NIP-98). Sign the final form of the request — the event commits to its exact URL, method, and body — immediately before sending:

```swift
var request = URLRequest(url: URL(string: "https://api.example.com/upload")!)
request.httpMethod = "POST"
request.httpBody = body
try await request.setNostrAuthorization(signer: signer)  // any NostrSigning
```

Without a `URLRequest`, sign ``EventTemplate/httpAuthorization(url:method:payload:)`` and encode the event with ``HTTPAuth/authorizationHeaderValue(for:)``:

```swift
let event = signer.sign(.httpAuthorization(url: uploadURL, method: "POST", payload: body))
let header = try HTTPAuth.authorizationHeaderValue(for: event)
```

A server (or any verifier) runs the full NIP-98 check chain with ``HTTPAuth/validate(authorization:url:method:payload:tolerance:now:)`` and trusts the returned event's ``Event/publicKey`` as the authenticated identity:

```swift
do {
    let event = try HTTPAuth.validate(
        authorization: authorizationHeader, url: requestURL, method: "POST", payload: body)
    let authenticatedPublicKey = event.publicKey
} catch .timestampOutOfTolerance {
    // Stale or clock-skewed credential: ask the client to sign a fresh one.
} catch {
    // `error` is an `HTTPAuth.ValidationError` naming the failed check.
}
```

## Join and Post to a Relay-based Group

NIP-29 relay-based groups live on a single relay, and everything a user sends carries the group id in an "h" tag. Ask to join with ``EventTemplate/groupJoinRequest(groupID:inviteCode:reason:)`` (kind 9021, with an invite code for closed groups), then post content of any kind with ``EventTemplate/groupContent(groupID:kind:content:tags:previous:)`` — here a NIP-C7 chat message — with "previous" timeline references that ``Groups`` samples from recently seen group events:

```swift
let join = signer.sign(.groupJoinRequest(groupID: "abcdef", inviteCode: "A7fjq2"))

let message = signer.sign(
    .groupContent(
        groupID: "abcdef",
        kind: .chatMessage,
        content: "hello",
        previous: Groups.previousReferences(from: recentEvents, excludingAuthor: signer.publicKey)
    )
)
```

Admins send ``Groups/ModerationAction``s with ``EventTemplate/groupModeration(_:groupID:previous:reason:)``, and ``EventTemplate/groupLeaveRequest(groupID:reason:)`` leaves the group.

The relay answers with the group's state as relay-signed kind-39xxx events, which carry the group id in a "d" tag instead (user-sent events use "h"). Parse them with ``Groups/Metadata`` and its siblings, pinning the author to the relay's public key so an impostor's event is rejected:

```swift
let metadata = try Groups.Metadata(event: stateEvent, relayPublicKey: relayPublicKey)
print(metadata.name ?? metadata.groupID, metadata.isPrivate ? "private" : "public")
```

## Talk to a Single Relay

``RelayConnection`` is one actor-isolated relay socket with its own connect/keepalive/reconnect state machine. Open it, publish, and read messages as an async stream.

Relays are addressed by ``RelayURL``: a `ws` or `wss` URL that ``RelayURL/init(string:)`` validates and normalizes to its canonical form — lowercased scheme and host, no root trailing slash, no default port — so every spelling of a relay compares equal. Anything else throws a ``RelayURL/Error`` naming why: ``RelayURL/Error/malformed``, ``RelayURL/Error/unsupportedScheme(_:)``, ``RelayURL/Error/missingHost``, ``RelayURL/Error/containsFragment``, or ``RelayURL/Error/containsCredentials``.

```swift
let relay = RelayConnection(url: try RelayURL(string: "wss://relay.example.com"))
try await relay.connect()

try await relay.send(.event(note))

try await relay.subscribe(
    id: .random(), filters: [Filter(authors: [publicKey], kinds: [.textNote], limit: 20)])
for await message in await relay.messages() {
    if case .event(_, let event) = message {
        print(event.content)
    }
}

await relay.disconnect()
```

The message stream survives automatic reconnections; the `for await` loop ends when the
connection is torn down for good — on ``RelayConnection/disconnect()`` or once auto-reconnect
gives up after ``ReconnectPolicy/maximumAttempts`` failed attempts.

The transport is injectable through ``WebSocketSessionFactory``: the default ``URLSessionWebSocketFactory`` backs it with `URLSession`, while a host can supply a native socket (for example OkHttp on Android) or a test can supply an in-memory fake — so the connection logic runs on platforms whose Foundation lacks WebSocket support.

```swift
struct OkHttpWebSocketFactory: WebSocketSessionFactory {
    func makeWebSocket(with request: URLRequest) -> any WebSocketSession {
        OkHttpWebSocket(request: request)   // your WebSocketSession over the platform socket
    }
}

let relay = RelayConnection(
    url: try RelayURL(string: "wss://relay.example.com"),
    webSocketFactory: OkHttpWebSocketFactory()
)
try await relay.connect()
```
