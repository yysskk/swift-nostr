// # NostrWalletConnect
//
// A Swift implementation of NIP-47 Nostr Wallet Connect
// (https://github.com/nostr-protocol/nips/blob/master/47.md): a protocol that lets an application
// control a remote Lightning wallet over Nostr relays.
//
// The headline use case is *completing a zap payment*: NostrCore can build a zap request and fetch
// a BOLT-11 invoice from a recipient's LNURL endpoint, but it cannot pay that invoice. A Nostr
// Wallet Connect connection closes that gap by asking a remote wallet to pay the invoice and return
// the payment preimage.
//
// This module builds on top of NostrCore, reusing its event, signing, encryption, and relay
// primitives. Callers that work with those core types `import NostrCore` directly (it is not
// re-exported). Start from a wallet's connection string with `WalletConnectURI`.
