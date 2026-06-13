# ``NostrClient``

A modern Swift library for the Nostr protocol with full concurrency support.

## Overview

NostrClient provides a type-safe, actor-based API for interacting with the Nostr network. It handles relay connections, event signing, subscriptions, and encrypted direct messages out of the box.

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

### Events and Filters

- ``Event``
- ``UnsignedEvent``
- ``Tag``
- ``Filter``
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

### Cryptography and Keys

- ``KeyPair``
- ``PublicKey``
- ``EventSigner``
- ``Mnemonic``
- ``KeyDerivation``
- ``BIP39WordList``
- ``Bech32``

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
- ``SealedMessage``
- ``GiftWrap``
- ``DirectMessageRelayList``

### NIP-19 Entities

- ``NIP19Entity``
- ``NProfile``
- ``NEvent``
- ``NAddr``

### Relay Connections

- ``RelayPool``
- ``RelayConnection``
- ``RelayConnectionConfig``
- ``RelayPoolConfig``
- ``RelayConnectionState``
- ``RelayMessage``
- ``ClientMessage``
- ``RelayResponsePrefix``
- ``RelayInformation``
- ``AuthenticationMode``

### Outbox Model (NIP-65)

- ``RelayListMetadata``
- ``RelayListEntry``
- ``RelayUsage``
- ``GossipRelayPolicy``

### Lightning Zaps (NIP-57)

- ``ZapReceipt``
- ``Bolt11Invoice``
- ``LNURL``
- ``LNURLPayResponse``

### Verification and Attestation

- ``InternetIdentifier``
- ``OpenTimestamps``

### Errors

- ``NostrError``
