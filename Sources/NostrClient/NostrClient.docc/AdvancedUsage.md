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

### Reactions (NIP-25)

React to a received message with ``NostrClient/reactToDirectMessage(_:reaction:expiration:strategy:)``.
The reaction is gift-wrapped exactly like a message, so it stays private and sender-anonymous:

```swift
try await client.reactToDirectMessage(message, reaction: "🤙")
```

### Encrypted File Messages (NIP-17 kind 15)

A file message carries an *encrypted* file's URL together with the keys needed to decrypt it. Encrypt
the bytes with ``EncryptedFile/encrypt(_:)``, upload the ciphertext to any host (Blossom, NIP-96, …),
then send the URL and keys with
``NostrClient/sendFileMessage(url:mimeType:encryption:size:dimensions:blurhash:to:expiration:strategy:)``:

```swift
let encrypted = try EncryptedFile.encrypt(imageData)
let url = try await upload(encrypted.ciphertext)  // your transport
try await client.sendFileMessage(
    url: url, mimeType: "image/jpeg", encryption: encrypted, to: "recipientPubkeyHex"
)
```

On receipt, download the ciphertext and decrypt it with the file's keys using
``EncryptedFile/decrypt(_:key:nonce:)``:

```swift
let blob = try await download(file.url)  // your transport
let data = try EncryptedFile.decrypt(blob, key: file.decryptionKey, nonce: file.decryptionNonce)
```

### Disappearing Messages (NIP-40)

Pass an `expiration` to attach a NIP-40 expiration timestamp to a message's gift wraps. Relays stop
serving the event after that time, and the received ``DirectMessage`` exposes ``DirectMessage/expiresAt``
so clients can hide it once it lapses.

```swift
try await client.sendDirectMessage(
    "This self-destructs in an hour",
    to: "recipientPubkeyHex",
    expiration: Date().addingTimeInterval(3600)
)
```

### Receiving Mixed Payloads

``NostrClient/directMessagePayloads(limit:)`` delivers messages, reactions, and file messages
together as a ``DirectMessagePayload``, so one loop can handle every kind:

```swift
for await payload in try await client.directMessagePayloads() {
    switch payload {
    case .message(let message):
        print("\(message.senderPubkey): \(message.content)")
    case .reaction(let reaction):
        print("\(reaction.senderPubkey) reacted \(reaction.content) to \(reaction.messageId)")
    case .file(let file):
        let blob = try await download(file.url)  // your transport
        let data = try EncryptedFile.decrypt(blob, key: file.decryptionKey, nonce: file.decryptionNonce)
        print("received \(file.mimeType ?? "file"), \(data.count) bytes")
    }
}
```

### DM Relay Lists (NIP-17 kind 10050)

NIP-17 routes each gift wrap to its addressee's advertised DM relays. Advertise where you receive
DMs with ``NostrClient/publishDirectMessageRelayList(relays:strategy:)`` (NIP-17 suggests 1–3
relays), connect your own inbox relays before receiving with
``NostrClient/connectDirectMessageInboxRelays()``, and look up another user's DM relays with
``NostrClient/fetchDirectMessageRelayList(for:timeout:)``:

```swift
try await client.publishDirectMessageRelayList(relays: ["wss://inbox.example.com"])
try await client.connectDirectMessageInboxRelays()

let dmRelays = try await client.fetchDirectMessageRelayList(for: "recipientPubkeyHex")
print("Receives DMs on: \(dmRelays?.relays ?? [])")
```

When sending, each gift wrap is routed to its addressee's advertised DM relays — the recipient copy
to the recipient's, the sender's self-copy to the sender's own — discovered from each user's kind
10050, falling back to the relay pool when a user has published no DM relay list.

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
let nprofile = try profile.encoded

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
    Contact(pubkey: "pubkey1", relayURL: "wss://relay.example.com", petname: "alice"),
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

## Remote Signing (NIP-46)

``NostrClient/setSigner(_:)-(NostrSigning)`` accepts any ``NostrCore/NostrSigning`` — a local
``NostrCore/EventSigner`` or a remote NIP-46 signer (a `RemoteSigner` from the `NostrConnect`
library), so the private key can live in a separate "bunker" the app never touches. The signer's
public key is resolved once and cached, so ``NostrClient/publicKey`` and ``NostrClient/npub`` stay
synchronous.

A remote signer drives the generic paths — ``NostrClient/sign(_:)``,
``NostrClient/publish(_:strategy:)``, and NIP-42 authentication. Build an
``NostrCore/UnsignedEvent`` under ``NostrClient/publicKey``, sign it, and publish it:

```swift
import NostrConnect

let signer = try RemoteSigner(bunker: try BunkerURI(string: "bunker://..."))
try await client.setSigner(signer)   // any NostrSigning

guard let pubkey = await client.publicKey else { return }
let signed = try await client.sign(
    UnsignedEvent(pubkey: pubkey, kind: .textNote, content: "Signed by my bunker"))
try await client.publish(signed)
```

The convenience helpers (``NostrClient/publishTextNote(content:tags:strategy:)``, the other
`publish*` methods, and the direct-message helpers) require a local key and throw
``NostrCore/NostrError/localSignerRequired`` for a remote signer — a deliberate boundary, since
they build and sign events internally rather than accepting a pre-signed one.

## Relay-based Groups (NIP-29)

A NIP-29 group lives on a single relay and is identified by a short id; the relay enforces
membership and permissions. Every group flow targets exactly that relay (added to the pool and
connected on demand), signing goes through the active signer — so a remote NIP-46 signer works
too — and private groups require NIP-42 AUTH, which the automatic responder answers once a
signer is set.

### Share Links and Joining

Groups are shared as the `naddr` of their kind-39000 metadata event, sometimes with an invite
code appended as `?invite=<code>`. ``GroupReference`` parses both parts, and
``NostrClient/joinGroup(_:inviteCode:reason:strategy:)`` applies the parsed code automatically
(closed groups accept a valid code without waiting for an admin):

```swift
let group = try GroupReference(naddrString: "naddr1...?invite=A7fjq2")
try await client.joinGroup(group)

// Later, ask to be removed (the relay answers with a kind-9001 removal):
try await client.leaveGroup(group)
```

Share a group you hold a reference to with ``GroupReference/shareableString()``, which
round-trips the invite code.

### Timeline and Chat

``NostrClient/subscribeToGroupTimeline(_:kinds:since:limit:)`` follows the group's content —
events carrying its "h" tag — from its relay. Keep the events you see: the spec asks each
message to reference a few recent timeline events in a "previous" tag so an out-of-context
rebroadcast is detectable, and `Groups.previousReferences(from:excludingAuthor:maxCount:)`
samples them for you. Check inbound events' references against what you have seen with
`Groups.unknownPreviousReferences(of:knownEventIDs:)`:

```swift
var recent: [Event] = []
let timeline = try await client.subscribeToGroupTimeline(group)
for await event in timeline.events {
    let unknown = Groups.unknownPreviousReferences(of: event, knownEventIDs: recent.map(\.id))
    if !unknown.isEmpty {
        print("timeline references I have not seen: \(unknown)")
    }
    recent.append(event)
}

// NIP-29 defines no content kinds of its own; the default is the NIP-C7 chat message (kind 9).
try await client.publishGroupMessage(
    "gm group",
    in: group,
    previous: Groups.previousReferences(from: recent, excludingAuthor: await client.publicKey)
)
```

### Moderation

Admins request changes with moderation events (kinds 9000-9002, 9005, and 9007-9010); the relay checks the author's
role and answers with an OK message. `Groups.ModerationAction` covers the whole
set — put/remove user, edit metadata, delete an event, create/delete the group, create an
invite code, and update the pin list:

```swift
try await client.publishGroupModeration(
    .putUser(pubkey: newMemberPubkey, roles: ["moderator"]),
    in: group,
    reason: "welcome aboard"
)
```

Parse received moderation events for an admin or audit UI with
`Groups.ModerationRequest`.

### Validated Group State

The relay publishes each group's current state as relay-signed kind-39xxx events: metadata
(39000), admins (39001), members (39002), roles (39003), and pins (39005).
``NostrClient/fetchGroupState(for:authorPubkey:timeout:)`` fetches a snapshot in one round
trip, newest event per kind. With a known ``GroupReference/relayPubkey`` — an `naddr` share
link carries it as the coordinate's author — events by any other author or with an invalid
signature are dropped before the pick:

```swift
let state = try await client.fetchGroupState(for: group)
print(state.metadata?.name ?? group.id)
print("private:", state.metadata?.isPrivate ?? false)
print("admins:", state.admins?.admins.map(\.pubkey) ?? [])
```

Never treat ``GroupState/members`` as exhaustive — relays may withhold or truncate the member
list. To check your own standing, derive it from the kind-9000/9001 moderation history with
`Groups.membership(of:in:)` instead (the latest event targeting the pubkey wins):

```swift
if let pubkey = await client.publicKey {
    var filter = Filter.groupTimeline(groupID: group.id, kinds: [.groupPutUser, .groupRemoveUser])
    filter.pubkeyReferences = [pubkey]
    let history = try await client.fetch(filters: [filter])
    switch Groups.membership(of: pubkey, in: history) {
    case .member(let roles):
        print("member, roles: \(roles)")
    case .removed:
        print("removed from the group")
    case nil:
        print("no record — assume not a member")
    }
}
```

### The Simple Group List (NIP-51 kind 10009)

Other clients discover which groups a user is in — and detect a group migrating to another
relay — from the kind-10009 simple group list, so keep it updated as the user joins and
leaves. Unlike the group flows, ``NostrClient/publishSimpleGroupList(_:strategy:)`` broadcasts
to the whole pool, and private entries are NIP-44-encrypted with the local key, so a remote
signer throws `NostrError.localSignerRequired`:

```swift
var list = try await client.fetchSimpleGroupList() ?? SimpleGroupList()
list.publicEntries.append(GroupListEntry(group, name: "Cool Group"))
if !list.relayURLs.contains(group.relayURL) {
    list.relayURLs.append(group.relayURL)
}
try await client.publishSimpleGroupList(list)
```

Each ``GroupListEntry`` converts back to a ``GroupReference`` via ``GroupListEntry/reference``
for joining or subscribing.

> Note: LiveKit AV rooms (kind 39004 and the `.well-known` JWT flow) are not modeled — only
> the kind-39000 `livekit` flag is parsed. NIP-22 comment threads are a separate NIP and not
> part of this library's NIP-29 surface.

## Outbox Model (NIP-65)

The outbox (gossip) model routes reads and writes to each user's declared relays instead of
broadcasting everywhere. Publish your relay list (kind 10002) with
``NostrClient/publishRelayList(read:write:strategy:)``, then let the client resolve and connect the
right relays automatically.

```swift
// Publish your own relay list: where you read (inbox) and write (outbox)
try await client.publishRelayList(
    read: ["wss://inbox.example.com"],
    write: ["wss://relay.example.com", "wss://relay2.example.com"]
)

// Fetch another user's relay list (cached for routing)
let relayList = try await client.fetchRelayList(for: "pubkey...")
print("Writes to: \(relayList?.writeRelays ?? [])")
```

An **outbox read** subscribes to each author on *their* write relays, resolving and connecting
relays on demand with ``NostrClient/subscribeOutbox(authors:kinds:limit:)``:

```swift
let outbox = try await client.subscribeOutbox(authors: ["pubkey1", "pubkey2"])
for await event in outbox.events {
    print("Note: \(event.content)")
}
```

A **gossip publish** routes an event to the author's write relays plus the inbox (read) relays of
every pubkey it mentions in `p` tags, with ``NostrClient/publishGossip(_:strategy:)``:

```swift
let signer = EventSigner(keyPair: keyPair)
let note = try signer.signTextNote(content: "gm!", tags: [.pubkey("alice_pubkey")])
try await client.publishGossip(note)
```

By default the client adds and connects resolved relays on demand (capped per resolve). Pass
`gossipPolicy: .requirePresent` (a ``GossipRelayPolicy``) to `NostrClient(...)` to route only to
relays already in the pool.

## Lightning Zaps (NIP-57)

The full sender flow: resolve the recipient's LNURL-pay endpoint, sign a zap request, fetch the
Lightning invoice, and verify the zap receipt once it arrives over relays. Paying the bolt11 invoice
is the caller's job (use a Lightning wallet).

```swift
// 1. Resolve the recipient's LNURL-pay endpoint from their lud16 lightning address (read from
//    their profile metadata), then GET it to read the pay parameters.
guard let serviceURL = LNURL.payServiceURL(forLightningAddress: "alice@example.com") else { return }
let (data, _) = try await URLSession.shared.data(from: serviceURL)
let pay = try JSONDecoder().decode(LNURLPayResponse.self, from: data)
guard pay.supportsZaps, let providerPubkey = pay.nostrPubkey else { return }

// 2. Sign a zap request (kind 9734) — note it is NOT published to relays.
let signer = EventSigner(keyPair: keyPair)
let zapRequest = try signer.signZapRequest(
    recipientPubkey: "recipientPubkeyHex",
    relays: ["wss://relay.example.com"],     // where the recipient's wallet should publish the receipt
    amountMillisats: 21_000,
    lnurl: LNURL.encode(serviceURL),
    comment: "great post!"
)

// 3. Fetch the bolt11 invoice from the callback, then pay it with a Lightning wallet.
let bolt11 = try await pay.fetchInvoice(
    amountMillisats: 21_000, zapRequest: zapRequest, lnurl: LNURL.encode(serviceURL))
// …pay `bolt11` with your wallet. You can also decode it on its own (the initializer is failable):
if let invoice = Bolt11Invoice(bolt11) {
    // invoice.amountMillisats, .paymentHash, .descriptionHash, .expirySeconds
}

// 4. When the kind-9735 zap receipt arrives over relays, verify it is authentic.
if let receipt = ZapReceipt(event: receiptEvent) {
    try receipt.validate(lnurlProviderPubkey: providerPubkey, expectedAmountMillisats: 21_000)
    // receipt.recipientPubkey, receipt.amountMillisats, receipt.zappedEventId, …
}
```

The ``EventSigner/signZapRequest(recipientPubkey:relays:amountMillisats:lnurl:eventId:eventCoordinate:comment:)``,
``LNURLPayResponse/fetchInvoice(amountMillisats:zapRequest:lnurl:urlSession:)``, ``Bolt11Invoice``,
and ``ZapReceipt/validate(lnurlProviderPubkey:expectedAmountMillisats:)`` APIs each work standalone,
so you can adopt only the parts of the flow you need.

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
