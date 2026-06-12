# Advanced Usage

Direct messages, encryption, relay configuration, and low-level APIs.

## Private Direct Messages (NIP-17)

NostrClient implements NIP-17 private direct messages using NIP-44 encryption and NIP-59 gift wrap for sender anonymity.

### Sending

```swift
try await client.setNsec("nsec1...")

let result = try await client.sendDirectMessage(
    "Hello privately!",
    to: "recipientPubkeyHex"
)

// The same unsigned rumor is wrapped twice: once for the recipient and once
// for the sender (the NIP-17 self-copy for sent history / multi-device sync).
// Match relay echoes against the rumor id:
let echoKey = result.rumor.id
```

The rumor is never signed — not even transiently — because a leaked signed
kind-14 would be cryptographic proof of authorship and destroy deniability.
A failed self-copy publish is non-fatal; the send succeeds when the
recipient copy is accepted. The per-relay outcomes of both publishes are
reported on the result as `recipientPublishResult` and `selfCopyPublishResult`.

### Receiving

``NostrClient/directMessages(limit:)`` delivers messages already unwrapped and
parsed (gift wraps that fail to decrypt are skipped):

```swift
for await message in try await client.directMessages() {
    print("From: \(message.senderPubkey)")
    print("Content: \(message.content)")
}
```

For the raw gift-wrap events, use ``NostrClient/subscribeToDirectMessages(limit:)``
and parse manually:

```swift
let giftWraps = try await client.subscribeToDirectMessages()
for await giftWrap in giftWraps.events {
    let dm = try await client.parseDirectMessage(giftWrap)
    print("From: \(dm.senderPubkey): \(dm.content)")
}
```

### Parsing Received Gift Wraps

```swift
let dm = try await client.parseDirectMessage(giftWrapEvent)
print("Message: \(dm.content)")
```

## NIP-44 Encryption and NIP-59 Gift Wrap

For lower-level access to encryption primitives:

```swift
let senderKeyPair = try KeyPair()
let recipientPubkey = "..."

// Seal a message (NIP-44)
let sealed = try SealedMessage.seal(
    "secret message",
    for: recipientPubkey,
    using: senderKeyPair
)

// Open a sealed message
let plaintext = try sealed.open(
    from: senderPubkey,
    using: recipientKeyPair
)

// Gift wrap an event (NIP-59)
let wrapped = try GiftWrap.wrap(
    event: rumorEvent,
    senderKeyPair: senderKeyPair,
    recipientPubkey: recipientPubkey
)

// Unwrap
let unwrapped = try GiftWrap.unwrap(
    giftWrap: wrappedEvent,
    recipientKeyPair: recipientKeyPair
)
```

## BIP-39 Mnemonic Key Derivation (NIP-06)

```swift
// Generate a new mnemonic and keypair
let (mnemonic, keyPair) = try KeyPair.generate(wordCount: 24)
print("Mnemonic: \(mnemonic.phrase)")

// Restore from mnemonic phrase
let restored = try KeyPair(
    mnemonicPhrase: "leader monkey parrot ring guide ...",
    passphrase: "",
    account: 0
)

// Work with Mnemonic directly
let mnemonic = try Mnemonic.generate(wordCount: 12)
let seed = try mnemonic.toSeed(passphrase: "optional passphrase")
let privateKey = try KeyDerivation.deriveNostrKey(seed: seed, account: 0)
```

## NIP-05 Internet Identifier Verification

```swift
// Verify an internet identifier
let result = try await InternetIdentifier.verify("alice@example.com")
print("Pubkey: \(result.pubkey)")
print("Relays: \(result.relays)")

// Verify against expected pubkey
try await InternetIdentifier.verify(
    "alice@example.com",
    expectedPubkey: "expected_hex..."
)

// Look up pubkey only
let pubkey = try await InternetIdentifier.lookupPubkey("alice@example.com")
```

## NIP-19 Entities

NostrClient encodes and decodes the NIP-19 bech32 entities ``NIP19Entity``,
``NProfile``, ``NEvent``, and ``NAddr`` in addition to the plain `npub`/`nsec`
exposed on ``KeyPair``. The TLV entities carry optional relay hints.

```swift
// Profile reference with relay hints (nprofile)
let profile = try NProfile(
    publicKey: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    relays: ["wss://relay.example.com"]
)
let nprofile = profile.encoded

// Event reference (nevent) built from a fetched event
let nevent = try NEvent(event: event, relays: ["wss://relay.example.com"]).encoded

// Addressable event coordinate (naddr) for replaceable events (e.g. long-form)
let naddr = try NAddr(
    identifier: "my-article",
    author: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    kind: 30023,
    relays: ["wss://relay3.example.com"]
).encoded
```

Decode an arbitrary entity through the unified entry point, or a known type
directly:

```swift
switch try NIP19Entity.decode(nprofile) {
case .nprofile(let p):
    print("pubkey: \(p.publicKey), relays: \(p.relays)")
case .nevent(let e):
    print("event: \(e.eventId), kind: \(String(describing: e.kind))")
case .naddr(let a):
    print("addr: \(a.kind):\(a.author):\(a.identifier)")
case .npub(let hex), .nsec(let hex), .note(let hex):
    print(hex)
}

// Typed decode (throws if the prefix does not match)
let parsed = try NEvent(bech32String: nevent)
```

## Contact Lists (NIP-02)

```swift
let contacts = [
    Contact(pubkey: "pubkey1", relayUrl: "wss://relay.example.com", petname: "alice"),
    Contact(pubkey: "pubkey2")
]
try await client.publishContactList(contacts)

// Extract contacts from a kind-3 event
if let contacts = event.contacts {
    for contact in contacts {
        print("\(contact.petname ?? contact.pubkey)")
    }
}
```

## OpenTimestamps (NIP-03)

```swift
// Attach OTS attestation to an event
let ots = OpenTimestamps(base64EncodedOTS: "...")
let tags = [ots.toTag()]

// Check for OTS on received events
if let ots = event.openTimestamps {
    print("Has OTS: \(ots.otsData)")
}
```

## Relay Information (NIP-11)

Fetch a relay's information document — name, supported NIPs, limits, fees —
over HTTP before or after connecting:

```swift
let info = try await RelayInformation.fetch(fromRelayURLString: "wss://relay.example.com")
print(info.name ?? "unknown")
print(info.supportedNIPs ?? [])
print(info.limitation?.maxSubscriptions ?? 0)
print(info.limitation?.authRequired ?? false)
```

## Client Authentication (NIP-42)

Relays can demand authentication before serving sensitive data (typically DMs) or accepting
events. The relay sends an AUTH challenge; the client answers it with a signed kind-22242
event.

### Automatic Authentication

With a signer set, ``NostrClient`` answers challenges automatically — including fresh
challenges after a reconnect. Publishes rejected with `auth-required:` wait for the AUTH
round-trip and retry once, and subscriptions the relay closed with `auth-required:` are
re-requested after authentication succeeds:

```swift
let client = NostrClient()
try await client.setNsec("nsec1...")  // automatic from here on
```

Automatic authentication reveals the signer's pubkey to any relay that asks. Switch to
manual mode when that link should only be made deliberately:

```swift
await client.setAuthenticationMode(.manual)
```

### Manual Authentication

In manual mode, challenges surface as ``SubscriptionEvent/auth(relayURL:challenge:)`` on
active subscriptions; answer them explicitly:

```swift
for await event in try await client.subscribe(filters: [filter]) {
    if case .auth(let relayURL, _) = event {
        try await client.authenticate(relayURL: relayURL)
    }
}
```

### Authentication on a Direct Connection

``RelayConnection`` exposes the same building blocks: the stored
``RelayConnection/authenticationChallenge``, ``RelayConnection/authenticate(using:)`` /
``RelayConnection/authenticate(with:)`` for signing and sending the answer, and
``RelayConnection/authenticatedPubkeys`` for the session's authenticated identities.

```swift
let connection = try RelayConnection(urlString: "wss://relay.example.com")
try await connection.connect()
// ... the relay sends ["AUTH", "<challenge>"] ...
try await connection.authenticate(using: signer)
print(await connection.isAuthenticated)
```

A pre-signed event (e.g. from a remote signer) can be sent with
``RelayConnection/authenticate(with:)``. Detect why a relay denied an operation with
``RelayResponsePrefix`` — `auth-required:` means authenticate and retry, `restricted:`
means the pubkey is not allowed even when authenticated.

## Relay Configuration

### Connection Configuration

```swift
let config = RelayConnectionConfig(
    connectionTimeout: 10,
    sendTimeout: 10,
    publishAckTimeout: 30,
    pingInterval: 30,
    autoReconnect: true,
    maxReconnectAttempts: 10,
    initialReconnectDelay: 1,
    maxReconnectDelay: 60,
    reconnectBackoffMultiplier: 2
)
try await client.addRelay("wss://relay.example.com", config: config)
```

Liveness is detected with periodic WebSocket pings (`pingInterval`); an idle relay
that simply has no messages to deliver is never torn down. The pong wait is bounded
by `connectionTimeout`.

### Pool Configuration

```swift
let poolConfig = RelayPoolConfig(
    maxDeduplicationCacheSize: 10000,
    deduplicationCacheTTL: 300
)
let client = NostrClient(config: poolConfig)
```

### Publish Strategies

``PublishStrategy`` controls how many relay acknowledgments a publish waits for
before returning. The event is always sent to every targeted relay; returning
early never cancels the in-flight sends to slower relays.

```swift
// Default: return as soon as the fastest relay acknowledges
try await client.publish(event)

// Wait until 2 relays acknowledge
try await client.publish(event, strategy: .quorum(2))

// Wait for every relay to settle (accept, reject, or time out)
try await client.publish(event, strategy: .allSettled)

// Change the pool-wide default
let poolConfig = RelayPoolConfig(defaultPublishStrategy: .allSettled)
```

Publishing returns a ``PublishResult`` with the per-relay outcome, enabling
delivery indicators and selective retries. With `.firstAck`, relays that had
not settled when the call returned are reported as pending:

```swift
let result = try await client.publish(event)
print("accepted:", result.acceptedRelays)
print("failed:", result.failedRelays)
print("still in flight:", result.pendingRelays)
```

The convenience publish methods (``NostrClient/publishTextNote(content:tags:strategy:)``,
``NostrClient/publishReaction(to:content:strategy:)``, ...) accept the same `strategy:`
parameter and return a ``PublishedEvent`` carrying both the signed event and its
``PublishResult``:

```swift
let note = try await client.publishTextNote(content: "Hello!", strategy: .quorum(2))
print("id:", note.id)  // Event properties are forwarded
print("accepted:", note.result.acceptedRelays)
```

Publishing fails fast with ``NostrError/notConnected`` on relays that are not
connected — the publish path never connects inline. Connect relays up front with
``NostrClient/connect()`` and let auto-reconnect handle drops.

## Low-Level Relay API

### Direct Relay Connection

```swift
let connection = try RelayConnection(urlString: "wss://relay.example.com")
await connection.connect()

try await connection.subscribe(
    subscriptionId: "sub1",
    filters: [Filter(kinds: [1], limit: 10)]
)

for await message in await connection.messages() {
    switch message {
    case .event(let subId, let event):
        print("Event: \(event.content)")
    case .endOfStoredEvents:
        print("EOSE")
    default:
        break
    }
}
```

### Manual Event Signing

```swift
let signer = EventSigner(keyPair: try KeyPair())

let unsigned = UnsignedEvent(
    pubkey: signer.publicKey,
    kind: .textNote,
    tags: [.hashtag("test")],
    content: "Manually signed"
)

let signed = try signer.sign(unsigned)
let isValid = try signed.verify()
```

## Event Deduplication

``RelayPool`` automatically deduplicates events across relays using an in-memory cache. To reset:

```swift
await client.clearDeduplicationCache()
```

Cache size and TTL are configurable via ``RelayPoolConfig``.
