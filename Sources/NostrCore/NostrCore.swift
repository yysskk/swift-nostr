// NostrCore
//
// Shared Nostr protocol primitives, cryptography, and the relay transport seam
// used by both `NostrClient` and `NostrWalletConnect`. Splitting these
// foundations into their own module lets each higher-level library depend only
// on what it needs, without coupling to the other.
//
// Types are migrated into this module incrementally; see the package README for
// the current layout.
