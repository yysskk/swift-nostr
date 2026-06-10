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
try await client.addRelays(["wss://relay.damus.io", "wss://nos.lol"])
try await client.connect()

let event = try await client.publishTextNote(content: "Hello, Nostr!")
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``NostrClient/NostrClient``

### Advanced

- <doc:AdvancedUsage>

### Models

- ``Event``
- ``UnsignedEvent``
- ``Filter``
- ``SubscriptionEvent``
- ``RelayMessage``
- ``UserMetadata``
- ``NIP19Entity``
- ``NProfile``
- ``NEvent``
- ``NAddr``

### Cryptography

- ``KeyPair``
- ``PublicKey``
- ``EventSigner``
- ``Mnemonic``
- ``SealedMessage``
- ``GiftWrap``

### Direct Messages

- ``DirectMessage``
- ``DirectMessageBuilder``
- ``DirectMessageParser``

### Relay Management

- ``RelayPool``
- ``RelayConnection``
- ``RelayConnectionConfig``
- ``RelayPoolConfig``
- ``RelayConnectionState``

### Supporting Types

- ``Contact``
- ``InternetIdentifier``
- ``RelayInformation``
- ``OpenTimestamps``
- ``NostrError``
- ``Bech32``
