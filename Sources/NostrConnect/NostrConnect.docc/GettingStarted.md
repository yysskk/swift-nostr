# Getting Started

Connect to a remote signer and sign your first event.

## Installation

NostrConnect ships in the same package as `NostrClient`. Add the package dependency in
`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/yysskk/swift-nostr", from: "0.5.0")
]
```

Then add the `NostrConnect` product to your target. It re-exports the `NostrCore` primitives
its API surfaces (`Event`, `EventTemplate`, `KeyPair`, …):

```swift
.target(
    name: "YourTarget",
    dependencies: ["NostrConnect"]
)
```

Or add via Xcode: File → Add Package Dependencies → Enter the repository URL.

## Connect to a Remote Signer

A remote signer authorizes a client by issuing a `bunker://` token. Parse it into a ``BunkerURI``
and create a ``RemoteSigner``:

```swift
import NostrConnect

let bunker = try BunkerURI(string: "bunker://...")
let signer = try RemoteSigner(bunker: bunker)
```

The token's host is the signer's public key, held as a `PublicKey` in
``BunkerURI/remoteSignerPublicKey``. It must be canonical lowercase hex: anything else, uppercase hex
included, throws ``RemoteSignerError/invalidURI(reason:)``.

The session signs and encrypts with a *client* identity — a fresh random keypair by default — so the
user's main Nostr key never leaves the signer. Commands connect to the relay and perform the
`connect` handshake automatically on first use; call ``RemoteSigner/connect()`` explicitly to
surface connection errors up front.

To resume a previously authorized session, persist the client keypair and pass it back in:

```swift
let signer = try RemoteSigner(bunker: bunker, clientKeyPair: savedClientKeyPair)
```

To have the signer grant operations up front rather than challenging the user for each, list them
as ``RemoteSignerPermission`` values. They are sent in the `connect` request; requesting none (the
default) leaves them out:

```swift
let signer = try RemoteSigner(
    bunker: bunker,
    requesting: [.signEvent(kind: .textNote), .nip44Encrypt, .nip44Decrypt])
```

A `nostrconnect://` invitation carries its permissions in the URI instead (see below).

## Start the Handshake From the Client

Alternatively the *client* can begin the handshake with a `nostrconnect://` invitation. Generate one
with ``NostrConnectURI/invitation(clientKeyPair:relays:permissions:name:url:image:)``, show its
``NostrConnectURI/stringValue`` as a QR code or deep link, and create a ``RemoteSigner`` from it. The
signer's public key is unknown until it scans the invitation and replies, so wait for it with
``RemoteSigner/awaitConnection()``:

```swift
let clientKeyPair = try KeyPair()
let invitation = try NostrConnectURI.invitation(
    clientKeyPair: clientKeyPair, relays: [try RelayURL(string: "wss://relay.example")])
displayQRCode(invitation.stringValue)

let signer = try RemoteSigner(invitation: invitation, clientKeyPair: clientKeyPair)

// Resolves once the signer accepts. The response's secret is validated against the invitation, per
// NIP-46, so a spoofed reply is ignored; a reply that never arrives throws
// ``RemoteSignerError/timedOut``.
let remoteSignerPublicKey: PublicKey = try await signer.awaitConnection()
```

Once ``RemoteSigner/awaitConnection()`` returns, the session is connected and the commands below work
exactly as for a `bunker://` session.

## Prove the User's Public Key

``RemoteSigner/userPublicKey()`` asks the signer which key it signs with. This may differ from
``RemoteSigner/remoteSignerPublicKey`` — the signer's session identity — and it is cached after the
first call. A reply that is not a canonical hex key throws
``RemoteSignerError/responseValidationFailed``:

```swift
let userPublicKey: PublicKey = try await signer.userPublicKey()
print("Signing as \(userPublicKey.npub)")
```

## Sign an Event

``RemoteSigner`` is a `NostrSigning`, so it signs an ``EventTemplate`` as the user's public key. The
signer returns a complete signed event, which is verified locally and checked against the request
before it is returned:

```swift
let signed = try await signer.sign(.textNote("Signed by my bunker"))
print(signed.id, try signed.verify())
```

## Handle Authentication Challenges

A signer may answer a request with an `auth_url` challenge, asking the user to authorize the
operation in a browser. Iterate ``RemoteSigner/authChallenges()`` and present each URL; the
originating request stays pending — its timeout extended to
``RemoteSigner/Config/authChallengeTimeout`` — until the signer answers:

```swift
Task {
    for await challenge in await signer.authChallenges() {
        // Open challenge.url so the user can approve the pending challenge.method request.
        openInBrowser(challenge.url)
    }
}

// This may block on an auth challenge the first time; the browser flow resolves it.
let signed = try await signer.sign(.textNote("Signed by my bunker"))
```

## Encrypt and Decrypt

The signer can encrypt and decrypt with the user's key on the client's behalf, for both NIP-44 and
legacy NIP-04:

```swift
// recipientPublicKey and senderPublicKey are PublicKey values.
let ciphertext = try await signer.nip44Encrypt("hello", to: recipientPublicKey)
let plaintext = try await signer.nip44Decrypt(ciphertext, from: senderPublicKey)

let legacyCiphertext = try await signer.nip04Encrypt("hello", to: recipientPublicKey)
let legacyPlaintext = try await signer.nip04Decrypt(legacyCiphertext, from: senderPublicKey)
```

## Check Liveness and End the Session

```swift
try await signer.ping()   // throws unless the signer replies "pong"

// Ask the signer to logout (best effort) and tear down the connection.
await signer.logout()
```

``RemoteSigner/disconnect()`` tears down the relay connection without notifying the signer, failing
any in-flight requests with ``RemoteSignerError/notConnected``.

## Call Other Methods

``RemoteSignerMethod`` is an open set: a signer may implement methods this package has no typed
command for. ``RemoteSigner/send(_:params:)`` sends any method with its positional string
parameters and returns the response's `result` string as is:

```swift
let method = RemoteSignerMethod(rawValue: "get_session_info")
let info = try await signer.send(method)
```

## Handle Errors

Commands throw ``RemoteSignerError``. A signer that rejects a request reports it as
``RemoteSignerError/signerError(message:)``; a returned event that fails to verify or does not match
the request is ``RemoteSignerError/responseValidationFailed``:

```swift
do {
    let signed = try await signer.sign(.textNote("Signed by my bunker"))
    print(signed.id)
} catch let RemoteSignerError.signerError(message) {
    print("The signer refused: \(message)")
} catch RemoteSignerError.responseValidationFailed {
    print("The returned event did not match the request")
} catch RemoteSignerError.timedOut {
    print("The signer did not respond in time")
}
```
