# Advanced Usage

Direct messages, encryption, relay configuration, and low-level APIs.

## Private Direct Messages (NIP-17)

NostrClient implements NIP-17 private direct messages using NIP-44 encryption and NIP-59 gift wrap for sender anonymity.

### Sending

```swift
try await client.setNsec("nsec1...")

try await client.sendDirectMessage(
    "Hello privately!",
    to: "recipientPubkeyHex"
)
```

### Receiving

```swift
try await client.subscribeToDirectMessages { event in
    let dm = try await client.parseDirectMessage(event)
    print("From: \(dm.senderPubkey)")
    print("Content: \(dm.content)")
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
    relays: ["wss://relay.damus.io"]
)
let nprofile = profile.encoded

// Event reference (nevent) built from a fetched event
let nevent = try NEvent(event: event, relays: ["wss://relay.damus.io"]).encoded

// Addressable event coordinate (naddr) for replaceable events (e.g. long-form)
let naddr = try NAddr(
    identifier: "my-article",
    author: "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d",
    kind: 30023,
    relays: ["wss://relay.nostr.band"]
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
    Contact(pubkey: "pubkey1", relayUrl: "wss://relay.damus.io", petname: "alice"),
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

## Relay Configuration

### Connection Configuration

```swift
let config = RelayConnectionConfig(
    connectionTimeout: 10,
    operationTimeout: 30,
    autoReconnect: true,
    maxReconnectAttempts: 10,
    initialReconnectDelay: 1,
    maxReconnectDelay: 60,
    reconnectBackoffMultiplier: 2
)
try await client.addRelay("wss://relay.damus.io", config: config)
```

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

Publishing fails fast with ``NostrError/notConnected`` on relays that are not
connected — the publish path never connects inline. Connect relays up front with
``NostrClient/connect()`` and let auto-reconnect handle drops.

## Low-Level Relay API

### Direct Relay Connection

```swift
let connection = try RelayConnection(urlString: "wss://relay.damus.io")
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
    tags: [["t", "test"]],
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
