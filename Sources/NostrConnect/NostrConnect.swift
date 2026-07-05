// # NostrConnect
//
// A Swift implementation of NIP-46 Nostr Connect
// (https://github.com/nostr-protocol/nips/blob/master/46.md): a protocol that lets an application
// delegate signing to a remote signer (a "bunker") that holds the user's private key.
//
// Instead of embedding an `nsec` in the app, a client sends signing requests — sign an event,
// encrypt or decrypt a message, prove a public key — to a remote signer over Nostr relays, and the
// signer answers with the result. Requests and responses are exchanged as kind 24133 events whose
// content is a NIP-44 encrypted JSON-RPC-like envelope.
//
// This module builds on top of NostrCore, reusing its event, signing, encryption, and relay
// primitives. Callers that work with those core types `import NostrCore` directly (it is not
// re-exported).
//
// This file establishes the model layer: the remote-signing method set, the request and response
// envelope, permission tokens, the authentication-challenge value, and the module's errors. The
// connection URIs, relay transport, and session actor follow in subsequent work.
