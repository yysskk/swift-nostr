# ``NostrClient``

The high-level, multi-relay Nostr client built on `NostrCore`.

## Overview

NostrClient provides a type-safe, actor-based API for interacting with the Nostr network. It handles relay connections, event signing, subscriptions, and encrypted direct messages out of the box.

The lower-level primitives it builds on — the event model, keys and signing, NIP-44 encryption, NIP-19 encoding, the relay protocol messages, and a single `RelayConnection` — live in `NostrCore`, which `NostrClient` re-exports.

- Actor-based concurrency with full `Sendable` compliance.
- Multi-relay management with automatic reconnection.
- NIP-44 encryption and NIP-59 gift wrap for private messaging.
- BIP-39 mnemonic key generation (NIP-06).

```swift
import NostrClient

let client = NostrClient()
try await client.identity.setNsec("nsec1...")
try await client.relays.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])

let note = try await client.events.publishTextNote(content: "Hello, Nostr!")
```

### Feature namespaces

The client's API is reached through eight namespaces rather than as a flat list of methods on
`NostrClient`, so completion shows the operations of one feature area at a time:

| Namespace | What it covers |
| --- | --- |
| ``NostrClient/identity`` | The signer, its public key, and NIP-42 relay authentication |
| ``NostrClient/relays`` | Pool membership, connection lifecycle, and the underlying ``RelayPool`` |
| ``NostrClient/events`` | Publishing, one-time fetches, NIP-23 long-form content |
| ``NostrClient/subscriptions`` | Live subscriptions as async sequences |
| ``NostrClient/routing`` | NIP-65 outbox/gossip and NIP-17 DM relay lists |
| ``NostrClient/messages`` | NIP-17 private direct messages |
| ``NostrClient/groups`` | NIP-29 relay-based groups and the kind-10009 group list |
| ``NostrClient/lists`` | NIP-51 lists and sets |

Each namespace is a `Sendable` value holding nothing but the client, and each conforms to a
capability protocol — so a feature can depend on the slice it needs instead of the whole client,
and be tested against a stub:

```swift
struct ChatViewModel {
    let messages: any NostrMessaging
}

ChatViewModel(messages: client.messages)
```

`NostrClient` itself exposes only its initializers and these namespaces.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AdvancedUsage>
- ``NostrClient/NostrClient``

> The event model, keys, signing, encryption, encoding, relay protocol messages, and a single
> `RelayConnection` are defined in `NostrCore`. See its documentation for `Event`, `KeyPair`,
> `EventSigner`, `Filter`, `Bech32`, and the rest.

### Feature Namespaces

- ``NostrIdentityAPI``
- ``NostrRelaysAPI``
- ``NostrEventsAPI``
- ``NostrSubscriptionsAPI``
- ``NostrRoutingAPI``
- ``NostrMessagesAPI``
- ``NostrGroupsAPI``
- ``NostrListsAPI``

### Capabilities

- ``NostrIdentityProviding``
- ``NostrRelayManaging``
- ``NostrEventPublishing``
- ``NostrEventFetching``
- ``NostrSubscribing``
- ``NostrRelayRouting``
- ``NostrMessaging``
- ``NostrGroupManaging``
- ``NostrListManaging``

### Profiles and Contacts

- ``UserMetadata``
- ``Contact``

### Subscriptions

- ``SubscriptionSequence``
- ``SubscriptionEvent``

### Publishing

- ``PublishStrategy``
- ``PublishResult``
- ``PublishedEvent``
- ``PublishRelayStatus``

### Encrypted Messaging (NIP-17)

- ``DirectMessage``
- ``DirectMessageReaction``
- ``DirectMessageFile``
- ``DirectMessagePayload``
- ``DirectMessageSequence``
- ``DirectMessagePayloadSequence``
- ``DirectMessageBuilder``
- ``DirectMessageParser``
- ``SendDirectMessageResult``
- ``EncryptedFile``
- ``GiftWrap``
- ``DirectMessageRelayList``

### NIP-19 Entities

- ``NIP19Entity``
- ``NProfile``
- ``NEvent``
- ``NAddr``

### Content References (NIP-27)

- ``NostrContentReference``

### Relay Pool

- ``RelayPool``
- ``RelayPoolConfig``
- ``AuthenticationMode``

### Outbox Model (NIP-65)

- ``RelayListMetadata``
- ``RelayListEntry``
- ``RelayUsage``
- ``GossipRelayPolicy``

### Lists (NIP-51)

- ``NostrList``
- ``NostrListSet``

### Relay-based Groups (NIP-29)

- ``GroupReference``
- ``GroupState``
- ``SimpleGroupList``
- ``GroupListEntry``

### Long-form Content (NIP-23)

- ``LongFormContent``

### Moderation (NIP-56)

- ``ReportType``

### Lightning Zaps (NIP-57)

- ``ZapReceipt``
- ``Bolt11Invoice``

### Verification and Attestation

- ``InternetIdentifier``
- ``OpenTimestamps``
