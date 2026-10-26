# ``NostrCore``

The shared Nostr protocol primitives, cryptography, and relay transport that `NostrClient`, `NostrWalletConnect`, and `NostrConnect` build on.

## Overview

NostrCore is the foundation layer of swift-nostr. It holds the pieces that are not specific to any one higher-level library: the event model, key handling and signing, NIP-44 encryption, NIP-19 bech32 encoding, the NIP-01 relay protocol messages, and a single-relay connection behind a platform-independent WebSocket transport seam.

Depend on NostrCore directly when you only need these primitives — for example to sign an event, derive a key, or drive one relay connection — without the higher-level relay pool, gossip routing, and direct-messaging features that live in `NostrClient`.

```swift
import NostrCore

let signer = try EventSigner(nsec: "nsec1...")
let event = try signer.sign(.textNote("Hello, Nostr!"))
let isValid = try event.verify()
```

## Topics

### Essentials

- <doc:GettingStarted>

### Events and Tags

- ``Event``
- ``EventTemplate``
- ``UnsignedEvent``
- ``EventID``
- ``Signature``
- ``Timestamp``
- ``Tag``
- ``Event/Tag/Name``
- ``Filter``

### Keys and Identity

- ``KeyPair``
- ``PublicKey``
- ``Mnemonic``
- ``KeyDerivation``
- ``BIP39WordList``

### Signing and Encryption

- ``NostrSigning``
- ``EventSigner``
- ``ProofOfWork``
- ``SealedMessage``
- ``EncryptedPrivateKey``

### HTTP Authorization (NIP-98)

- ``HTTPAuth``

### Relay-based Groups (NIP-29)

- ``Groups``

### Encoding

- ``Bech32``

### Relay Protocol

- ``ClientMessage``
- ``RelayMessage``
- ``EventCount``
- ``RelayResponsePrefix``
- ``RelayRejection``
- ``RelayInformation``

### Relay Connection

- ``RelayURL``
- ``RelayConnection``
- ``RelayConnectionConfig``
- ``RelayConnectionState``

### WebSocket Transport Seam

- ``RelayConnection/init(url:webSocketFactory:config:)``
- ``WebSocketSession``
- ``WebSocketSessionFactory``
- ``URLSessionWebSocketFactory``
- ``WebSocketMessage``
- ``WebSocketCloseCode``

### Relay Transport

- ``RelayTransport``
- ``RelayConnectionTransport``

### Lightning (NIP-57)

- ``LNURL``
- ``LNURLPayResponse``
- ``LNURLInvoiceResponse``

### Errors

- ``RelayConnection/Error``
- ``Bech32/Error``
- ``PublicKey/Error``
- ``EventID/Error``
- ``Signature/Error``
- ``KeyPair/Error``
- ``Mnemonic/Error``
- ``EncryptedPrivateKey/Error``
- ``LNURL/Error``
- ``SealedMessage/Error``
- ``Event/VerificationError``
- ``ProofOfWork/Error``
- ``RelayMessage/Error``
- ``RelayURL/Error``
- ``HTTPAuth/AuthorizationError``
- ``EventTemplate/ZapRequestError``
