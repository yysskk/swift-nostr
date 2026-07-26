# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **NIP-98 HTTP Auth**: `HTTPAuth` builds and signs kind-27235 authorization events and encodes
  them as `Authorization: Nostr <base64>` header values, with a
  `URLRequest.setNostrAuthorization(signer:)` convenience that signs the request's URL, method,
  and body. Works with any `NostrSigning` signer, local or remote. On the server side,
  `HTTPAuth.validate(authorization:url:method:payload:tolerance:now:)` performs the full NIP-98
  check chain — scheme, decoding, kind, signature, timestamp window, URL, method, and body
  hash — returning the verified event, with each failure reported as a typed
  `HTTPAuth.ValidationError`.
- **NIP-29 Relay-based groups (core events)**: group event kind constants,
  `h`/`previous`/`code`/`role`/`group` tag constructors, join/leave request builders,
  group-scoped content events, and timeline-reference helpers under the new `Groups` namespace.
- **NIP-29 Relay-based groups (state)**: typed parsing of relay-generated group state —
  `Groups.Metadata`, `Groups.AdminList`, `Groups.MemberList`, `Groups.RoleList`, and
  `Groups.PinList` — plus membership derivation from moderation history and a
  `Filter.groupState` convenience.
- **NIP-29 Relay-based groups (moderation)**: typed `Groups.ModerationAction` builders for the
  eight moderation kinds (put-user, remove-user, edit-metadata, delete-event, create-group,
  delete-group, create-invite, update-pin-list) and `Groups.ModerationRequest` parsing for
  admin and audit views.
- **NIP-29 Relay-based groups (client)**: `GroupReference` (naddr share links with invite codes),
  `GroupState` snapshots, and `NostrClient` flows — `joinGroup`, `leaveGroup`,
  `publishGroupMessage`, `publishGroupModeration`, `fetchGroupMetadata`/`fetchGroupState` with
  relay-author validation, and `subscribeToGroupTimeline` — all scoped to the group's relay.
- **NIP-29 Relay-based groups (group list)**: the NIP-51 kind-10009 simple group list as a typed
  `SimpleGroupList`/`GroupListEntry` view over `NostrList` — including NIP-44 private entries —
  with `fetchSimpleGroupList` and `publishSimpleGroupList` on `NostrClient`.
- **Official NIP-44 vectors**: the canonical vector file from
  [paulmillr/nip44](https://github.com/paulmillr/nip44) is bundled as a test resource and run in
  full — conversation keys, message-key derivation, the padding table, every `encrypt_decrypt`
  payload and its maximum-length variants, and every rejection case — replacing the four
  hand-copied vectors that previously stood in for the suite.
- **Transport injection on a single relay**: the designated
  `RelayConnection(url:webSocketFactory:config:)` initializer is now public, so a host can drive one
  relay connection on a platform-native socket (for example an OkHttp-backed
  `WebSocketSessionFactory` on Android) or on an in-memory fake — matching the injection `RelayPool`
  and `NostrClient` already expose.
- **Transport injection in a NIP-46 or NIP-47 session**: the shared `RelayConnectionTransport` now
  takes a `webSocketFactory:` and a `config:`, so a remote-signer session or a wallet connection can
  run its relays on a platform-native socket or an in-memory fake and tune their timeouts, keepalive,
  and reconnection. Neither was reachable before: the per-module transports it replaces hard-coded
  `URLSession` and `RelayConnectionConfig.default`.
- **String-based relay conveniences**: `NostrClient.count(filters:to:timeout:)` scopes a NIP-45
  count to a subset of relays; `NostrClient.removeRelay(_:)` removes a relay by URL string;
  `NostrClient.addRelay(_:config:)` accepts a per-relay `RelayConnectionConfig`; and
  `PublishResult.status(for:)` looks up a relay's publish status from any spelling of its URL
  string, resolved against the result's canonical keys.

### Fixed

- **NIP-44 padding is now validated strictly.** Decryption accepted any padded block long enough
  to hold the declared plaintext, so a payload carrying a valid MAC over non-canonical padding
  decrypted successfully. The block must now be exactly the 2-byte length prefix plus
  `calc_padded_len` of the declared length, matching the reference implementation; anything else
  throws `NostrError.invalidPadding`. Payloads produced by this or any other compliant
  implementation are unaffected.
- The decoded-payload size check in NIP-44 decryption used a minimum of 97 bytes, derived from a
  comment that undercounted the smallest ciphertext. The bounds are now the correct 99 to 65,603
  bytes, so more malformed payloads are refused before any key derivation.
- **`fetch` no longer idles its full timeout when nothing was targeted.** With zero resolved
  relays the fetch waited the entire timeout (default 10s) and then returned `[]`; it now fails
  fast with the new zero-relay errors (see Changed).
- **Duplicate sockets for differently-spelled URLs of the same relay.** The pool keyed
  connections by the raw `URL`, so `wss://Relay.Example.com/` and `wss://relay.example.com`
  produced two entries and two sockets to one relay; connections are now keyed by the
  normalized URL.
- **`RelayPool.subscribe` leaked state when every REQ send failed.** The subscription handler
  and the per-relay message-listener tasks stayed registered after the throw; a totally failed
  subscribe now removes the handler and cancels the listeners before surfacing the error.
- **`RelayPool.removeRelay` raced a concurrent re-add of the same relay.** The pool entry was
  removed only after the disconnect suspended, so an `addRelay` interleaving with the removal
  could receive a connection about to be torn down; the entry is now removed first.
- **A relay listed for both reading and writing under different spellings lost a direction.**
  `EventSigner.signRelayListMetadata(read:write:)` and `NostrClient.publishRelayList(read:write:)`
  compared the two lists as raw strings, so `wss://relay.example.com/` in `read` and
  `wss://relay.example.com` in `write` were treated as two relays and emitted as two conflicting
  `r` tags, which any NIP-65 reader collapses to whichever came first. Membership is now decided
  on the normalized URL, so equivalent spellings produce a single read+write entry that keeps the
  spelling and position of its first appearance.

### Changed

- **Breaking**: a remote NIP-46 signer now drives every `NostrClient` feature, not just the
  generic paths. The convenience `publish*` helpers, NIP-17 direct messages (send, react, file
  messages, and parsing), and NIP-51 private list/set items previously threw
  `NostrError.localSignerRequired` for a remote signer, because they reached past `NostrSigning`
  for a raw private key; they now build their events from the signer's public key and go through
  `sign`/`nip44Encrypt`/`nip44Decrypt`, which every signer already provides. Nothing in the
  library needs a local key any more, so `NostrError.localSignerRequired` is removed — a source
  break for code that switches over `NostrError` exhaustively or matches that case.
  Gift wrapping is the API this surfaces in: `GiftWrap.wrap(event:signer:recipientPubkey:)` and
  `GiftWrap.unwrap(giftWrap:recipient:)` take an `any NostrSigning` in place of a `KeyPair` (pass
  `EventSigner(keyPair:)` for a local key) and are now `async`, as are `DirectMessageBuilder` and
  `DirectMessageParser`, whose initializers take `signer:` instead of `keyPair:`. The outer gift
  wrap key stays ephemeral and locally generated; only the seal goes through the signer.
- **Single import**: `NostrClient`, `NostrWalletConnect`, and `NostrConnect` now re-export
  `NostrCore`; a separate `import NostrCore` is no longer required to use the primitives
  (`Event`, `KeyPair`, `Filter`, …) they surface.
- The package enables the `ExistentialAny` upcoming feature on every target, and CI compiles
  with `-warnings-as-errors` on the Linux and macOS jobs, so implicit existential spellings and
  new compiler warnings now fail the build instead of accumulating. No effect on consumers of
  the library.
- `RemoteSigner.awaitConnection()` now throws a distinct `RemoteSignerError.connectionInProgress`
  when another wait is already running on the session, instead of conflating that with
  `.notConnected`. The new case is additive but a source break for code that switches over
  `RemoteSignerError` exhaustively.
- **Breaking**: `Contact.relayUrl` is now `Contact.relayURL`, matching the `relayURL` spelling of the
  tag API it feeds (`Tag.pubkey(_:relayURL:petname:)`) and the Swift API Design Guidelines rule that
  acronyms are uniformly cased. The `relayUrl:` argument label on both `Contact` initializers is
  renamed to `relayURL:` as well. Because `Contact` is `Codable`, its JSON key changes from
  `relayUrl` to `relayURL`; clients that persist encoded contacts need to migrate stored data.
- **Breaking**: the `relayUrl:` argument label is now `relayURL:` on
  `EventSigner.signRepost(of:relayURL:)`, `NostrClient.publishReply(to:content:relayURL:strategy:)`,
  and `NostrClient.publishRepost(of:relayURL:strategy:)`, completing the `relayURL` spelling across
  the package.
- **Breaking**: relay-targeted operations now throw instead of silently succeeding against zero
  relays. `RelayPool.publish`/`subscribe`/`count` — and the `NostrClient` publish, subscribe,
  fetch, and count flows built on them — throw the new `NostrError.noRelaysInPool` when the pool
  is empty and `NostrError.noMatchingRelays` when none of the targeted URLs are in the pool
  (partial matches still proceed). Previously publish returned an empty result, subscribe
  reported 0 relays, count returned `[:]`, and fetch stalled to its timeout before returning
  `[]`. The two cases are additive but a source break for code that switches over `NostrError`
  exhaustively; `connectAll()` on an empty pool still returns 0.
- **Breaking**: relay pool keys are normalized. `addRelay`, `removeRelay`, `relay(for:)`, and
  targeted publish/subscribe/count canonicalize URLs — lowercased scheme and host, root trailing
  slash stripped, default ports stripped — so any spelling of the same relay routes to the one
  connection, re-adding a relay under a different spelling returns the existing connection, and
  publish results are keyed by the canonical URL.
- **Breaking**: relay targeting is string-based. The `to:` parameter of `RelayPool.publish`,
  `RelayPool.count`, `RelayPool.subscribe`, and of `NostrClient.subscribe`, `events`, and `fetch`
  is now `[String]?` instead of `Set<URL>?`: nil (the default) broadcasts to the whole pool, an
  empty array throws `noMatchingRelays`, duplicates de-dupe by normalized key, and an invalid
  string throws the new `NostrError.invalidRelayURL` — a target must parse, use a `ws`/`wss`
  scheme, have a host, and carry no fragment or user/password.
- **Breaking**: the relay-management surface validates strictly and drops its labels.
  `RelayPool.addRelay(url:)`/`addRelay(urlString:)` collapse into `addRelay(_:config:)` overloads
  taking a `String` or a `URL` — both now throw `invalidRelayURL` for a non-WebSocket URL — and
  `removeRelay(url:)` becomes `removeRelay(_:)` with a validating `String` overload (removing an
  absent relay stays a no-op). `RelayConnection(urlString:)` and the invalid-URL path of
  `connect(to:)` now throw `invalidRelayURL` instead of `connectionFailed`, and
  `NostrClient.authenticate(relayURL:)` throws `noMatchingRelays` instead of a generic
  `relayError` when the relay is not in the pool.
- **Breaking**: NIP-65/NIP-17 relay-list parsing skips non-WebSocket URLs. Routing sets built from
  kind-10002/10050 tags (and the gossip resolvers on top of them) now drop entries with a
  non-`ws(s)` scheme, a missing host, or a fragment/userinfo instead of keeping them as routing
  keys, and the resolved sets always carry canonical URL spellings.
- **Breaking**: `RemoteSignerTransport` and `WalletConnectTransport` are replaced by a single
  `NostrCore.RelayTransport`. The two protocols were the same six requirements with nothing
  NIP-specific in either, and their default implementations were the same actor twice over. For a
  custom transport this is a one-line rename — the requirements are unchanged and both libraries
  re-export `NostrCore`, so no import changes either. The shared default `RelayConnectionTransport`
  moves to `NostrCore` with them, and now throws `NostrError.notConnected` instead of
  `RemoteSignerError.notConnected` / `WalletConnectError.notConnected` when an operation reaches no
  relay; both of those cases remain, still thrown for the session-level failures they already
  covered.

## [0.6.0] - 2026-07-05

A large protocol and tooling release: ten new NIPs, a new `NostrConnect` library for
remote signing, a spec-compliance fix to NIP-44 encryption, and expanded test coverage.

### Added

- **NIP-13 Proof of Work**: `ProofOfWork` with leading-zero-bit `difficulty(ofHexId:)`,
  commitment-aware `validate(event:minimumDifficulty:)`, and a cooperative, cancellable
  `mine(event:difficulty:)`, plus `EventSigner.sign(_:proofOfWork:)`.
- **NIP-21 `nostr:` URIs**: `NIP19Entity(nostrURI:)` and `nostrURI`, rejecting `nsec` in both directions.
- **NIP-23 Long-form content**: `LongFormContent` (kind 30023 articles and 30024 drafts) with
  lossless metadata round-tripping, `naddr` addressing, and client publish/fetch helpers.
- **NIP-27 Content references**: `NostrContentReference` to find `nostr:` mentions in content and
  map them to `p`/`q`/`a` tags, plus a `Tag.quote` constructor.
- **NIP-45 Event counts**: `ClientMessage.count`/`RelayMessage.count`, `EventCount`, and
  `count(...)` on `RelayConnection`, `RelayPool`, and `NostrClient`.
- **NIP-46 Nostr Connect (remote signing)**: a new **`NostrConnect`** library — the `RemoteSigner`
  actor over a relay transport, both the signer-initiated `bunker://` and client-initiated
  `nostrconnect://` flows, `auth_url` challenges, and typed commands (sign, get_public_key, ping,
  nip44/nip04 encrypt/decrypt, switch_relays, logout).
- **NIP-49 Private key encryption**: `EncryptedPrivateKey` (`ncryptsec`) using scrypt and
  XChaCha20-Poly1305, plus `KeyPair.encryptedPrivateKey(password:)` / `KeyPair(ncryptsec:password:)`.
- **NIP-50 Search**: a `search` field on `Filter` and a `Filter.search(...)` convenience.
- **NIP-51 Lists**: standard lists (mute, pin, bookmarks) and parameterized sets (follow, relay,
  bookmark, curation, interest, emoji, …) as `NostrList` / `NostrListSet`, with NIP-44-self-encrypted
  private items and client publish/fetch helpers.
- **NIP-56 Reporting**: `ReportType`, `EventSigner.signReport(...)`, and `NostrClient.publishReport(...)`.
- **`NostrSigning` protocol** unifying local `EventSigner` and remote `RemoteSigner`; `NostrClient`
  gains `setSigner(_ : any NostrSigning)` and a public `sign(_:)`, and answers NIP-42 auth with either.
- Status badges and a Swift Package Index manifest (`.spi.yml`); a `CHANGELOG.md` and `CODE_OF_CONDUCT.md`.

### Fixed

- **NIP-44 encryption is now spec-compliant and interoperable.** The keystream used the AEAD
  ChaCha20 (block counter 1) and a floating-point padding calculation, so payloads did not match
  other Nostr clients. Encryption now uses bare ChaCha20 at counter 0 with the spec's integer
  padding, validated against the official NIP-44 vectors. **Payloads produced by earlier releases
  will not decrypt** — but they never interoperated with other clients.
- **Relay hardening**: `URLSessionWebSocket.cancel(with:)` degrades to `.invalid` instead of
  crashing on an unmapped close code, and automatic NIP-42 authentication failures are now
  observable via `RelayConnection.lastAuthenticationError`.

### Changed

- `ClientMessage`, `RelayMessage`, and `NostrError` gain new cases. These are additive but a source
  break for code that switches over them exhaustively.

## [0.5.0] - 2026-06-15

- Split the package into `NostrCore`, `NostrClient`, and `NostrWalletConnect` libraries.

## [0.4.0] - 2026-06-13

- NIP-47 Nostr Wallet Connect and NIP-57 Lightning zap support.

## [0.3.0] - 2026-06-11

- NIP-17 private direct messages, NIP-59 gift wrap, and NIP-44 encryption.

## [0.2.0] - 2026-04-10

- Multi-relay `RelayPool`, NIP-65 outbox model, and NIP-42 authentication.

## [0.1.0] - 2026-01-31

- Initial release: NIP-01 events, filters, subscriptions, and single-relay support.

[Unreleased]: https://github.com/yysskk/swift-nostr/compare/0.6.0...HEAD
[0.6.0]: https://github.com/yysskk/swift-nostr/compare/0.5.0...0.6.0
[0.5.0]: https://github.com/yysskk/swift-nostr/compare/0.4.0...0.5.0
[0.4.0]: https://github.com/yysskk/swift-nostr/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/yysskk/swift-nostr/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/yysskk/swift-nostr/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/yysskk/swift-nostr/releases/tag/0.1.0
