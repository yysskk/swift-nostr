# ``NostrCore``

The shared Nostr protocol primitives, cryptography, and relay transport that both `NostrClient` and `NostrWalletConnect` build on.

## Overview

NostrCore is the foundation layer of swift-nostr-client. It holds the pieces that are not specific to any one higher-level library: the event model, key handling and signing, NIP-44 encryption, NIP-19 bech32 encoding, the NIP-01 relay protocol messages, and a single-relay connection behind a platform-independent WebSocket transport seam.

Depend on NostrCore directly when you only need these primitives — for example to sign an event, derive a key, or drive one relay connection — without the higher-level relay pool, gossip routing, and direct-messaging features that live in `NostrClient`.

```swift
import NostrCore

let signer = try EventSigner(nsec: "nsec1...")
let event = try signer.signTextNote(content: "Hello, Nostr!")
let isValid = try event.verify()
```

## Topics

### Essentials

- <doc:GettingStarted>

### Events and Tags

- ``Event``
- ``UnsignedEvent``
- ``Tag``
- ``Filter``

### Keys and Identity

- ``KeyPair``
- ``PublicKey``
- ``Mnemonic``
- ``KeyDerivation``
- ``BIP39WordList``

### Signing and Encryption

- ``EventSigner``
- ``SealedMessage``

### Encoding

- ``Bech32``

### Relay Protocol

- ``ClientMessage``
- ``RelayMessage``
- ``RelayResponsePrefix``
- ``RelayInformation``

### Relay Connection

- ``RelayConnection``
- ``RelayConnectionConfig``
- ``RelayConnectionState``

### WebSocket Transport Seam

- ``WebSocketSession``
- ``WebSocketSessionFactory``
- ``URLSessionWebSocketFactory``
- ``WebSocketMessage``
- ``WebSocketCloseCode``

### Lightning (NIP-57)

- ``LNURL``
- ``LNURLPayResponse``
- ``LNURLInvoiceResponse``

### Errors

- ``NostrError``
