# ``NostrClient``

A modern Swift library for the Nostr protocol with full concurrency support.

## Overview

NostrClient provides a type-safe, actor-based API for interacting with the Nostr network. It handles relay connections, event signing, subscriptions, and encrypted direct messages out of the box.

The lower-level primitives it builds on — the event model, keys and signing, NIP-44 encryption, NIP-19 encoding, the relay protocol messages, and a single `RelayConnection` — live in `NostrCore` and must be imported from there (`import NostrCore`).

- Actor-based concurrency with full `Sendable` compliance.
- Multi-relay management with automatic reconnection.
- NIP-44 encryption and NIP-59 gift wrap for private messaging.
- BIP-39 mnemonic key generation (NIP-06).

```swift
import NostrClient

let client = NostrClient()
try await client.setNsec("nsec1...")
try await client.connect(to: ["wss://relay.example.com", "wss://relay2.example.com"])

let note = try await client.publishTextNote(content: "Hello, Nostr!")
```

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:AdvancedUsage>
- ``NostrClient/NostrClient``

> The event model, keys, signing, encryption, encoding, relay protocol messages, and a single
> `RelayConnection` are defined in `NostrCore`. See its documentation for `Event`, `KeyPair`,
> `EventSigner`, `Filter`, `Bech32`, and the rest.

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

### Relay Pool

- ``RelayPool``
- ``RelayPoolConfig``
- ``AuthenticationMode``

### Outbox Model (NIP-65)

- ``RelayListMetadata``
- ``RelayListEntry``
- ``RelayUsage``
- ``GossipRelayPolicy``

### Lightning Zaps (NIP-57)

- ``ZapReceipt``
- ``Bolt11Invoice``

### Verification and Attestation

- ``InternetIdentifier``
- ``OpenTimestamps``
