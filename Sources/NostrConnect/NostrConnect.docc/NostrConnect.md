# ``NostrConnect``

Delegate signing to a remote signer over Nostr with NIP-46 Nostr Connect.

## Overview

NostrConnect is a Swift implementation of [NIP-46 Nostr
Connect](https://github.com/nostr-protocol/nips/blob/master/46.md): a protocol that lets an
application delegate signing to a remote signer (a "bunker") that holds the user's private key. It
builds on `NostrCore`, reusing its event, signing, encryption, and relay primitives; add the
`NostrCore` product and `import NostrCore` to work with those types directly.

Instead of embedding an `nsec` in the app, a client sends signing requests — sign an event, encrypt
or decrypt a message, prove a public key — to the remote signer over Nostr relays, and the signer
answers with the result. The user's private key never leaves the signer.

- Actor-based ``RemoteSigner`` with full `Sendable` compliance.
- The `bunker://` connect handshake, with the connection secret presented automatically.
- Typed commands: sign an event, fetch the user public key, ping, NIP-44/NIP-04 encrypt and
  decrypt, and switch relays.
- Request/response correlation by the request `id`, with per-request timeouts.
- An `auth_url` challenge stream that keeps the request pending while the user authorizes.

```swift
import NostrConnect
import NostrCore

// Parse the signer's bunker:// token and start a session.
let bunker = try BunkerURI(string: "bunker://...")
let signer = try RemoteSigner(bunker: bunker)

// Prove the user's key and sign an event remotely.
let pubkey = try await signer.userPublicKey()
let unsigned = UnsignedEvent(pubkey: pubkey, kind: .textNote, content: "Signed by my bunker")
let signed = try await signer.sign(unsigned)
print(signed.id, try signed.verify())
```

## Topics

### Essentials

- <doc:GettingStarted>
- ``RemoteSigner``
- ``BunkerURI``
- ``NostrConnectURI``

### Methods and Permissions

- ``RemoteSignerMethod``
- ``RemoteSignerPermission``

### Authentication Challenges

- ``RemoteSignerAuthChallenge``

### Relay Transport

- ``RemoteSignerTransport``
- ``RelayConnectionTransport``

### Errors

- ``RemoteSignerError``
